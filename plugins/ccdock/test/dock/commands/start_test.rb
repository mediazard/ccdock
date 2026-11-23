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

  def test_happy_path_invokes_full_pipeline_and_writes_workspace_state
    with_dock_config do |config|
      # Stub every external interaction.
      Dock::Workspace.stubs(:already_present?).returns(false)
      # Stub workspace creation to just `mkdir -p` — Dir.chdir needs a real dir.
      Dock::Workspace.stubs(:create).with do |path|
        FileUtils.mkdir_p(path)
        true
      end
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:ssh_agent_ready?).returns(false)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:try_clone_volume).returns(:cloned)
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:register_wildcard).returns('ws-sc-1')

      cmd = Dock::Commands::Start.new(config: config)

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

      _, err = capture_subprocess_io_with_exit { cmd.call('sc-1') }
      assert_match(/Could not resolve web port/, err)
    end
  end

  def test_clone_named_volumes_iterates_clone_volumes_config
    with_dock_config(clone_volumes: %w[node_modules bundle_cache]) do |config|
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

      capture_io { cmd.call('sc-1') }
    end
  end

  # ---- in-place mode ---------------------------------------------------------

  def test_in_place_docks_in_the_existing_worktree
    with_in_place do |config, wt, cmd|
      Dock::Workspace.expects(:create).never
      order = sequence('caddy')
      Dock::Caddy.expects(:delete_route).with(slug: 'my-worktree').in_sequence(order)
      Dock::Caddy.expects(:register_wildcard).in_sequence(order).returns('ws')

      capture_io { cmd.call('ignored input') }

      metadata = JSON.parse(File.read(File.join(wt, config.metadata_filename)))
      assert_equal 'my-worktree', metadata['slug']
      assert_equal config.project_root, metadata['parent_dir']
      assert_equal wt, metadata['workspace_path']
      assert_equal true, metadata['in_place']
      assert_match(/^COMPOSE_PROJECT_NAME=my-worktree$/, File.read(File.join(wt, '.env')))
      assert_equal "*\n", File.read(File.join(wt, '.dock', '.gitignore'))
    end
  end

  def test_in_place_rerun_skips_volume_clone
    with_in_place(clone_volumes: %w[node_modules]) do |_config, wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns(wt)
      Dock::Docker.expects(:try_clone_volume).never

      out, = capture_io { cmd.call }
      assert_match(/Existing dock stack found; skipping volume clone/, out)
    end
  end

  def test_in_place_rerun_when_only_volumes_remain_after_compose_down
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns(nil)
      Dock::Docker.stubs(:project_volumes).returns(['my-worktree_postgres'])

      out, = capture_io { cmd.call }
      assert_match(/Existing dock stack found; skipping volume clone/, out)
    end
  end

  def test_in_place_aborts_when_slug_is_used_by_a_dock_elsewhere
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:project_working_dir).returns('/somewhere/else')
      Dock::Docker.expects(:compose).never

      _, err = capture_subprocess_io_with_exit { cmd.call }
      assert_match(/already used/, err)
      assert_match(/docker compose -p my-worktree down -v/, err)
    end
  end

  def test_in_place_refuses_reserved_slug
    with_in_place(folder: 'demoapp') do |_config, _wt, cmd|
      _, err = capture_subprocess_io_with_exit { cmd.call }
      assert_match(/reserved/, err)
    end
  end

  def test_in_place_uses_ticket_slug_for_long_story_folder
    folder = 'story-19531-allow-existing-clients-therapy-psychiatry-to-book-ongoing-' \
             'appointments-from-the-client-portal'
    with_in_place(folder: folder) do |config, wt, cmd|
      File.write(File.join(config.project_root, '.env.local'), "BAR=1\n")
      capture_io { cmd.call }

      metadata = JSON.parse(File.read(File.join(wt, config.metadata_filename)))
      assert_equal 'sc-19531', metadata['slug']
      assert_equal "https://app.sc-19531-#{config.base_host}", metadata['url']
      assert_match(/^HOST_DOMAIN=sc-19531-#{Regexp.escape(config.base_host)}$/, File.read(File.join(wt, '.env.local')))
    end
  end

  def test_in_place_works_without_input
    with_in_place do |config, wt, cmd|
      capture_io { cmd.call(nil) }
      assert File.exist?(File.join(wt, config.metadata_filename))
    end
  end

  # ---- SSH build -------------------------------------------------------------

  def test_builds_with_ssh_before_up_when_agent_ready
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:ssh_agent_ready?).returns(true)
      order = sequence('compose')
      Dock::Docker.expects(:compose).with(project: 'my-worktree', args: %w[up -d postgres redis]).in_sequence(order)
      Dock::Docker.expects(:compose).with(project: 'my-worktree', args: %w[build --ssh default web worker])
                  .in_sequence(order)
      Dock::Docker.expects(:compose).with(project: 'my-worktree', args: %w[up -d web worker]).in_sequence(order)

      capture_io { cmd.call }
    end
  end

  def test_skips_explicit_build_when_no_ssh_agent_key
    with_in_place do |_config, _wt, cmd|
      Dock::Docker.stubs(:ssh_agent_ready?).returns(false)
      Dock::Docker.expects(:compose).with(project: 'my-worktree', args: %w[up -d postgres redis])
      Dock::Docker.expects(:compose).with(project: 'my-worktree', args: %w[up -d web worker])
      Dock::Docker.expects(:compose).with(has_entry(args: %w[build --ssh default web worker])).never

      capture_io { cmd.call }
    end
  end

  private

  # Builds <outer>/<folder> as the linked worktree, with .env in the project
  # root, and stubs every external interaction. Yields (config, wt, cmd).
  def with_in_place(folder: 'My_Worktree', **overrides)
    with_dock_config(**overrides) do |config, project_dir|
      File.write(File.join(project_dir, '.env'), "FOO=1\n")
      wt = File.join(File.dirname(project_dir), folder)
      FileUtils.mkdir_p(wt)

      Dock::Workspace.stubs(:linked_worktree).returns({ root: wt, main_root: project_dir })
      Dock::Docker.stubs(:project_working_dir).returns(nil)
      Dock::Docker.stubs(:project_volumes).returns([])
      Dock::Docker.stubs(:compose).returns(nil)
      Dock::Docker.stubs(:ssh_agent_ready?).returns(false)
      Dock::Docker.stubs(:service_status).returns({ 'Health' => 'healthy' })
      Dock::Docker.stubs(:try_clone_volume).returns(:cloned)
      Dock::Docker.stubs(:published_port).returns(49_162)
      Dock::Caddy.stubs(:delete_route)
      Dock::Caddy.stubs(:register_wildcard).returns('ws')

      cmd = Dock::Commands::Start.new(config: config)
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
