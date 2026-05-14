# frozen_string_literal: true

require_relative '../test_helper'

class Dock::EnvFilesTest < Minitest::Test
  def test_apply_to_env_replaces_existing_project_name_line
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "PROJECT_NAME=\"demoapp\"\nFOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_includes content, 'PROJECT_NAME="sc-1-demoapp"'
      assert_includes content, 'FOO=bar', '.env should preserve unrelated keys'
    end
  end

  def test_apply_to_env_appends_compose_project_name_when_absent
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "FOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_match(/^COMPOSE_PROJECT_NAME=sc-1$/, content)
    end
  end

  def test_apply_to_env_appends_workroom_name
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => '' })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_match(/^WORKROOM_NAME=sc-1$/, content)
    end
  end

  def test_apply_to_env_strips_devcaddy_when_disabled_in_workspace
    # Rails apps gate Caddy on ENV.key?('DEVCADDY') — value-insensitive. The
    # implementation removes the line entirely rather than writing DEVCADDY=0.
    with_dock_config(disable_devcaddy_in_workspace: true) do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "DEVCADDY=1\nFOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      refute_match(/^DEVCADDY=/, content)
      assert_includes content, 'FOO=bar'
    end
  end

  def test_apply_to_env_preserves_devcaddy_when_disabled_flag_is_false
    with_dock_config(disable_devcaddy_in_workspace: false) do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "DEVCADDY=1\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      assert_match(/^DEVCADDY=1$/, File.read(File.join(ws, '.env')))
    end
  end

  def test_apply_to_env_local_replaces_host_domain
    with_dock_config do |config|
      ws = make_workspace(
        config, 'sc-1',
        files: { '.env.local' => "HOST_DOMAIN=dev.localhost\nOTHER=keep\n" }
      )
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env.local'))
      assert_match(/^HOST_DOMAIN=sc-1-dev\.localhost$/, content)
      assert_includes content, 'OTHER=keep'
    end
  end

  def test_apply_to_env_local_sets_dynamic_ports_to_zero
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env.local' => '' })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env.local'))
      assert_match(/^POSTGRES_PORT=0$/, content)
      assert_match(/^REDIS_PORT=0$/, content)
    end
  end

  def test_apply_to_env_local_strips_pre_existing_devcaddy
    with_dock_config(disable_devcaddy_in_workspace: true) do |config|
      ws = make_workspace(
        config, 'sc-1',
        files: { '.env.local' => "DEVCADDY=1\nFOO=bar\n" }
      )
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env.local'))
      refute_match(/^DEVCADDY=/, content)
      assert_includes content, 'FOO=bar'
    end
  end

  def test_apply_is_idempotent_across_reruns
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => '', '.env.local' => '' })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      first_env = File.read(File.join(ws, '.env'))
      first_local = File.read(File.join(ws, '.env.local'))

      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      assert_equal first_env, File.read(File.join(ws, '.env'))
      assert_equal first_local, File.read(File.join(ws, '.env.local'))
    end
  end

  def test_apply_is_a_noop_when_files_are_missing
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      refute File.exist?(File.join(ws, '.env'))
      refute File.exist?(File.join(ws, '.env.local'))
    end
  end

  def test_replace_or_append_replaces_existing_line
    content = "A=1\nKEY=old\nB=2\n"
    result = Dock::EnvFiles.replace_or_append(content, 'KEY', 'new')
    assert_equal "A=1\nKEY=new\nB=2\n", result
  end

  def test_replace_or_append_appends_when_key_missing
    result = Dock::EnvFiles.replace_or_append("A=1\n", 'KEY', 'new')
    assert_equal "A=1\nKEY=new\n", result
  end
end
