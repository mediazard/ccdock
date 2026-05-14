# frozen_string_literal: true

require_relative '../../test_helper'

class Dock::Commands::StartTest < Minitest::Test
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
      cmd.stubs(:run_dump_pipeline).returns(true)

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
      cmd.stubs(:run_dump_pipeline).returns(true)

      _, err = capture_subprocess_io_with_exit { cmd.call('sc-1') }
      assert_match(/Could not resolve web port/, err)
    end
  end

  private

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
