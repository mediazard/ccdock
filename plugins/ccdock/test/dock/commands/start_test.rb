# frozen_string_literal: true

require_relative '../../test_helper'

class Dock::Commands::StartTest < Minitest::Test
  def setup
    # This repo is itself a linked worktree: never let a test hit real detection.
    Dock::Workspace.stubs(:linked_worktree).returns(nil)
  end

  def teardown
    WebMock.reset!
  end

  def test_aborts_when_dump_file_is_missing
    with_dock_config do |config|
      cmd = Dock::Commands::Start.new(config: config)
      _, err = capture_subprocess_io_with_exit do
        cmd.call('sc-1')
      end
      assert_match(/Run \/dock-dump/, err)
    end
  end

  def test_happy_path_invokes_full_pipeline_and_writes_workspace_state
    with_dock_config do |config|
      # Pre-populate the dump file so ensure_dump_present! passes.
      FileUtils.mkdir_p(File.dirname(config.dump_path))
      File.write(config.dump_path, 'gz-bytes')

      # Stub every external interaction.
      Dock::Workspace.stubs(:already_present?).returns(false)
      # Stub workspace creation to just `mkdir -p` — Dir.chdir needs a real dir.
      Dock::Workspace.stubs(:create).with do |path|
        FileUtils.mkdir_p(path)
        true
      end
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:try_clone_volume).returns(:cloned)
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:register_wildcard).returns('ws-sc-1')

      # Stub the raw `system` (createdb) + the shell-free dump pipeline.
      cmd = Dock::Commands::Start.new(config: config)
      cmd.stubs(:system).returns(true)
      cmd.stubs(:run_dump_pipeline!).returns(nil)

      capture_io { cmd.call('sc-1', description: 'fix it') }

      ws_path = config.workspace_path_for('sc-1')
      assert File.directory?(ws_path), 'workspace dir should exist (make_workspace-like)'
      metadata = JSON.parse(File.read(File.join(ws_path, config.metadata_filename)))
      assert_equal 'sc-1', metadata['slug']
      assert_equal 'sc-1', metadata['ticket']
      assert_equal 'fix it', metadata['description']
      assert_equal 49_162, metadata['web_port']
      assert_equal "https://app.sc-1-#{config.base_host}", metadata['url']

      # Fingerprint marker is written.
      assert File.exist?(File.join(ws_path, config.fingerprint_filename))

      # Slug marker is written and contains the slug.
      assert_equal 'sc-1', File.read(File.join(ws_path, config.slug_marker_filename))
      assert_equal "*\n", File.read(File.join(ws_path, '.dock', '.gitignore'))
      refute metadata['in_place']
    end
  end

  def test_aborts_when_web_port_cannot_be_resolved
    with_dock_config do |config|
      FileUtils.mkdir_p(File.dirname(config.dump_path))
      File.write(config.dump_path, 'gz-bytes')

      Dock::Workspace.stubs(:already_present?).returns(false)
      # Stub workspace creation to just `mkdir -p` — Dir.chdir needs a real dir.
      Dock::Workspace.stubs(:create).with do |path|
        FileUtils.mkdir_p(path)
        true
      end
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:try_clone_volume).returns(:cloned)
      Dock::Docker.stubs(:published_port).returns(nil)

      cmd = Dock::Commands::Start.new(config: config)
      cmd.stubs(:system).returns(true)
      cmd.stubs(:run_dump_pipeline!).returns(nil)

      _, err = capture_subprocess_io_with_exit { cmd.call('sc-1') }
      assert_match(/Could not resolve web port/, err)
    end
  end

  def test_clone_named_volumes_iterates_clone_volumes_config
    with_dock_config(clone_volumes: %w[node_modules bundle_cache]) do |config|
      FileUtils.mkdir_p(File.dirname(config.dump_path))
      File.write(config.dump_path, 'gz-bytes')

      Dock::Workspace.stubs(:already_present?).returns(false)
      Dock::Workspace.stubs(:create).with do |path|
        FileUtils.mkdir_p(path)
        true
      end
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:register_wildcard).returns('ws-sc-1')

      clone_calls = []
      Dock::Docker.stubs(:try_clone_volume).with do |**kwargs|
        clone_calls << kwargs
        true
      end

      cmd = Dock::Commands::Start.new(config: config)
      cmd.stubs(:system).returns(true)
      cmd.stubs(:run_dump_pipeline!).returns(nil)

      capture_io { cmd.call('sc-1') }

      assert_equal(
        [
          { from: 'demoapp_node_modules', to: 'sc-1_node_modules' },
          { from: 'demoapp_bundle_cache', to: 'sc-1_bundle_cache' }
        ],
        clone_calls
      )
    end
  end

  def test_clone_named_volumes_is_a_noop_when_clone_volumes_is_empty
    with_dock_config do |config| # default clone_volumes: []
      FileUtils.mkdir_p(File.dirname(config.dump_path))
      File.write(config.dump_path, 'gz-bytes')

      Dock::Workspace.stubs(:already_present?).returns(false)
      Dock::Workspace.stubs(:create).with do |path|
        FileUtils.mkdir_p(path)
        true
      end
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:register_wildcard).returns('ws-sc-1')

      Dock::Docker.expects(:try_clone_volume).never

      cmd = Dock::Commands::Start.new(config: config)
      cmd.stubs(:system).returns(true)
      cmd.stubs(:run_dump_pipeline!).returns(nil)

      capture_io { cmd.call('sc-1') }
    end
  end

  # ---- in-place mode ---------------------------------------------------------

  def test_in_place_docks_in_the_existing_worktree
    with_in_place do |config, wt, cmd|
      Dock::Workspace.expects(:create).never
      cmd.expects(:run_dump_pipeline!).once
      order = sequence('caddy')
      Dock::Caddy.expects(:delete_route).with(slug: 'my-workroom').in_sequence(order)
      Dock::Caddy.expects(:register_wildcard).in_sequence(order).returns('ws')

      capture_io { cmd.call('ignored input') }

      metadata = JSON.parse(File.read(File.join(wt, config.metadata_filename)))
      assert_equal 'my-workroom', metadata['slug']
      assert_equal config.project_root, metadata['parent_dir']
      assert_equal wt, metadata['workspace_path']
      assert_equal true, metadata['in_place']
      assert_match(/^COMPOSE_PROJECT_NAME=my-workroom$/, File.read(File.join(wt, '.env')))
      assert_equal "*\n", File.read(File.join(wt, '.dock', '.gitignore'))
    end
  end

  def test_in_place_rerun_skips_dump_restore_and_volume_clone
    with_in_place(clone_volumes: %w[node_modules]) do |_config, wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns(wt)
      cmd.expects(:run_dump_pipeline!).never
      Dock::Docker.expects(:try_clone_volume).never

      out, = capture_io { cmd.call }
      assert_match(/Existing dock stack found/, out)
    end
  end

  def test_in_place_rerun_when_only_volumes_remain_after_compose_down
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns(nil)
      Dock::Docker.stubs(:project_volumes).returns(['my-workroom_postgres'])
      cmd.expects(:run_dump_pipeline!).never

      out, = capture_io { cmd.call }
      assert_match(/Existing dock stack found/, out)
    end
  end

  def test_in_place_aborts_when_slug_is_used_by_a_dock_elsewhere
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns('/somewhere/else')
      Dock::Docker.expects(:compose).never

      _, err = capture_subprocess_io_with_exit { cmd.call }
      assert_match(/already used/, err)
      assert_match(/docker compose -p my-workroom down -v/, err)
    end
  end

  def test_in_place_refuses_reserved_slug
    with_in_place(folder: 'demoapp') do |_config, _wt, cmd|
      _, err = capture_subprocess_io_with_exit { cmd.call }
      assert_match(/reserved/, err)
    end
  end

  def test_in_place_works_without_input
    with_in_place do |config, wt, cmd|
      capture_io { cmd.call(nil) }
      assert File.exist?(File.join(wt, config.metadata_filename))
    end
  end

  private

  # Builds <outer>/<folder> as the linked worktree, with .env in the project
  # root, and stubs every external interaction. Yields (config, wt, cmd).
  def with_in_place(folder: 'My_Workroom', **overrides)
    with_dock_config(**overrides) do |config, project_dir|
      FileUtils.mkdir_p(File.dirname(config.dump_path))
      File.write(config.dump_path, 'gz-bytes')
      File.write(File.join(project_dir, '.env'), "FOO=1\n")
      wt = File.join(File.dirname(project_dir), folder)
      FileUtils.mkdir_p(wt)

      Dock::Workspace.stubs(:linked_worktree).returns({ root: wt, main_root: project_dir })
      Dock::Docker.stubs(:project_working_dir).returns(nil)
      Dock::Docker.stubs(:project_volumes).returns([])
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:try_clone_volume).returns(:cloned)
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:delete_route)
      Dock::Caddy.stubs(:register_wildcard).returns('ws')

      cmd = Dock::Commands::Start.new(config: config)
      cmd.stubs(:system).returns(true)
      cmd.stubs(:run_dump_pipeline!).returns(nil)
      yield config, wt, cmd
    end
  end

  # Mimics capture_io but tolerates `exit 1` (Dock::Commands::Base#abort_with).
  def capture_subprocess_io_with_exit
    out, err = capture_io do
      yield
    rescue SystemExit
      # abort_with calls exit 1 — swallow so the test continues.
    end
    [out, err]
  end
end
