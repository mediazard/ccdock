# frozen_string_literal: true

require_relative '../../test_helper'

class Dock::Commands::DestroyTest < Minitest::Test
  def setup
    Dock::Docker.stubs(:project_working_dir).returns(nil)
    Dock::Workspace.stubs(:linked_worktree).returns(nil)
  end

  def teardown
    WebMock.reset!
  end

  def test_aborts_on_invalid_slug
    with_dock_config do |config|
      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call('../escape') }
      assert_match(/Invalid slug/, err)
    end
  end

  def test_aborts_when_workspace_directory_missing
    with_dock_config do |config|
      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call('sc-missing') }
      assert_match(/Workspace for 'sc-missing' not found/, err)
    end
  end

  def test_refuses_reserved_slug_matching_project_name
    with_dock_config do |config|
      # Create a workspace dir at <project_name> so the directory check passes
      # and the reserved guard is the rejection reason.
      make_workspace(config, config.project_name)
      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call(config.project_name) }
      assert_match(/reserved/, err)
    end
  end

  def test_refuses_reserved_slug_listed_in_config
    with_dock_config(reserved_slugs: ['hold']) do |config|
      make_workspace(config, 'hold')
      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call('hold') }
      assert_match(/reserved/, err)
    end
  end

  def test_aborts_when_metadata_file_missing
    with_dock_config do |config|
      make_workspace(config, 'sc-1')
      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call('sc-1') }
      assert_match(/metadata\.json missing/, err)
    end
  end

  def test_raises_on_fingerprint_mismatch
    with_dock_config do |config|
      slug = 'sc-1'
      metadata = { 'slug' => slug, 'parent_dir' => config.project_root, 'created_at' => 't0' }
      make_workspace(config, slug, files: {
                       config.metadata_filename => JSON.pretty_generate(metadata),
                       config.fingerprint_filename => 'tampered-value'
                     })

      # Fingerprint.verify! propagates Dock::Error rather than calling abort_with.
      error = assert_raises(Dock::Error) do
        Dock::Commands::Destroy.new(config: config).call(slug)
      end
      assert_match(/fingerprint mismatch/, error.message)
    end
  end

  def test_refuses_when_project_volumes_have_wrong_prefix
    with_dock_config do |config|
      slug = 'sc-1'
      build_valid_workspace(config, slug)
      # A volume not starting with "sc-1_" must trigger refusal.
      Dock::Docker.stubs(:project_volumes).returns(["#{slug}_postgres", 'mainproject_data'])

      _, err = capture_io_with_exit { Dock::Commands::Destroy.new(config: config).call(slug) }
      assert_match(/volumes do not all start with 'sc-1_'/, err)
    end
  end

  def test_removes_each_clone_volume_when_configured
    with_dock_config(clone_volumes: %w[node_modules bundle_cache]) do |config|
      slug = 'sc-1'
      build_valid_workspace(config, slug)
      Dock::Docker.stubs(:project_volumes).returns(["#{slug}_postgres"])
      Dock::Docker.stubs(:compose)
      Dock::Caddy.stubs(:delete_route)
      Dock::Inbox.stubs(:remove)

      removed = []
      cmd = Dock::Commands::Destroy.new(config: config)
      cmd.stubs(:system).with do |*args|
        # Only capture `docker volume rm <name>` calls; ignore unrelated ones.
        removed << args[3] if args[0..2] == %w[docker volume rm]
        true
      end

      capture_io { cmd.call(slug) }
      assert_equal %w[sc-1_node_modules sc-1_bundle_cache], removed
    end
  end

  def test_happy_path_runs_full_teardown_pipeline
    with_dock_config do |config|
      slug = 'sc-1'
      build_valid_workspace(config, slug)

      Dock::Docker.stubs(:project_volumes).returns(["#{slug}_postgres", "#{slug}_redis"])

      compose_calls = []
      Dock::Docker.stubs(:compose).with do |**kwargs|
        compose_calls << kwargs
        true
      end

      # `docker volume rm <slug>_<basename>` per clone_volumes entry is a raw
      # system call inside destroy.rb. Default clone_volumes is [], so no system
      # calls fire in this happy path — but we still stub to capture any leakage.
      cmd = Dock::Commands::Destroy.new(config: config)
      cmd.stubs(:system).returns(true)

      caddy_called = false
      Dock::Caddy.stubs(:delete_route).with do |kwargs|
        caddy_called = kwargs[:slug] == slug
        true
      end

      inbox_called = false
      Dock::Inbox.stubs(:remove).with do |kwargs|
        inbox_called = kwargs[:slug] == slug
        true
      end

      capture_io { cmd.call(slug) }

      assert_equal 1, compose_calls.size, 'should issue exactly one compose call'
      assert_equal slug, compose_calls.first[:project]
      assert_equal %w[down -v], compose_calls.first[:args]
      assert caddy_called, 'Caddy.delete_route should have been called'
      assert inbox_called, 'Inbox.remove should have been called'
    end
  end

  def test_in_place_dock_removes_only_dot_dock_and_leaves_workroom
    with_dock_config do |config, project_dir|
      slug = 'my-workroom'
      wt = File.join(File.dirname(project_dir), 'My_Workroom')
      write_valid_dock(config, wt, slug, 'in_place' => true)
      File.write(File.join(wt, 'keep.txt'), 'x')
      stub_teardown(slug, wt)

      out, = capture_io { Dock::Commands::Destroy.new(config: config).call(slug) }

      assert File.directory?(wt), 'workroom folder must survive'
      assert File.exist?(File.join(wt, 'keep.txt'))
      refute File.exist?(File.join(wt, '.dock')), '.dock should be removed'
      assert_match(/Workroom left untouched/, out)
    end
  end

  def test_in_place_dock_found_via_slug_marker_when_containers_are_gone
    with_dock_config do |config, project_dir|
      slug = 'my-workroom'
      wt = File.join(File.dirname(project_dir), 'My_Workroom')
      write_valid_dock(config, wt, slug, 'in_place' => true)
      File.write(File.join(wt, config.slug_marker_filename), slug)
      Dock::Workspace.stubs(:linked_worktree).returns({ root: wt, main_root: project_dir })
      stub_teardown(slug, wt)
      Dock::Docker.stubs(:project_working_dir).returns(nil)

      capture_io { Dock::Commands::Destroy.new(config: config).call(slug) }

      assert File.directory?(wt)
      refute File.exist?(File.join(wt, '.dock'))
    end
  end

  def test_old_style_dock_keeps_dot_dock
    with_dock_config do |config|
      slug = 'sc-1'
      build_valid_workspace(config, slug)
      stub_teardown(slug, config.workspace_path_for(slug))

      capture_io { Dock::Commands::Destroy.new(config: config).call(slug) }

      assert File.exist?(File.join(config.workspace_path_for(slug), config.metadata_filename))
    end
  end

  private

  def stub_teardown(slug, workspace_path)
    Dock::Docker.stubs(:project_working_dir).with(project: slug).returns(workspace_path)
    Dock::Docker.stubs(:project_volumes).returns(["#{slug}_postgres"])
    Dock::Docker.stubs(:compose)
    Dock::Caddy.stubs(:delete_route)
    Dock::Inbox.stubs(:remove)
  end

  def write_valid_dock(config, path, slug, extra = {})
    created_at = '2026-01-01T00:00:00Z'
    metadata = { 'slug' => slug, 'parent_dir' => config.project_root, 'created_at' => created_at }.merge(extra)
    fp = Dock::Fingerprint.compute(slug: slug, parent_dir: config.project_root, created_at: created_at)
    FileUtils.mkdir_p(File.join(path, '.dock'))
    File.write(File.join(path, config.metadata_filename), JSON.pretty_generate(metadata))
    File.write(File.join(path, config.fingerprint_filename), fp)
  end

  # Build a workspace with valid metadata + matching fingerprint so destroy passes
  # both the metadata-present and fingerprint-verify guards.
  def build_valid_workspace(config, slug)
    created_at = '2026-01-01T00:00:00Z'
    metadata = {
      'slug' => slug,
      'parent_dir' => config.project_root,
      'created_at' => created_at
    }
    fp = Dock::Fingerprint.compute(slug: slug, parent_dir: config.project_root, created_at: created_at)
    make_workspace(config, slug, files: {
                     config.metadata_filename => JSON.pretty_generate(metadata),
                     config.fingerprint_filename => fp
                   })
  end

  def capture_io_with_exit
    capture_io do
      yield
    rescue SystemExit
      # abort_with -> exit 1
    end
  end
end
