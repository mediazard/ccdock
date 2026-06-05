# frozen_string_literal: true

require_relative '../test_helper'

class Dock::EnvFilesTest < Minitest::Test
  def test_apply_to_env_writes_project_name_only_when_base_project_set
    # PROJECT_NAME / WORKROOM_NAME are Rails-ish opt-ins, gated on base_project.
    with_dock_config(base_project: 'myrails') do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "PROJECT_NAME=\"old\"\nFOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_includes content, 'PROJECT_NAME="sc-1-myrails"'
      assert_match(/^WORKROOM_NAME=sc-1$/, content)
      assert_includes content, 'FOO=bar', '.env should preserve unrelated keys'
    end
  end

  def test_apply_to_env_does_not_write_project_name_when_base_project_unset
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "FOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      refute_match(/^PROJECT_NAME=/, content, 'PROJECT_NAME stays absent without base_project')
      refute_match(/^WORKROOM_NAME=/, content, 'WORKROOM_NAME stays absent without base_project')
    end
  end

  def test_apply_to_env_appends_compose_project_name_when_absent
    # COMPOSE_PROJECT_NAME is always written — it's core compose namespacing,
    # not Rails-specific.
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "FOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_match(/^COMPOSE_PROJECT_NAME=sc-1$/, content)
    end
  end

  def test_apply_to_env_strips_rails_caddy_dev_when_disabled_in_workspace
    # Rails apps gate Caddy on ENV.key?('RAILS_CADDY_DEV') — value-insensitive.
    # The implementation removes the line entirely rather than writing =0.
    with_dock_config(disable_rails_caddy_dev_in_workspace: true) do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "RAILS_CADDY_DEV=1\nFOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      refute_match(/^RAILS_CADDY_DEV=/, content)
      assert_includes content, 'FOO=bar'
    end
  end

  def test_apply_to_env_strips_legacy_devcaddy_when_disabled_in_workspace
    # Adopters on the older gem version still set DEVCADDY. We strip both names.
    with_dock_config(disable_rails_caddy_dev_in_workspace: true) do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "DEVCADDY=1\nFOO=bar\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      refute_match(/^DEVCADDY=/, content)
      assert_includes content, 'FOO=bar'
    end
  end

  def test_apply_to_env_preserves_gate_vars_when_disabled_flag_is_false
    with_dock_config(disable_rails_caddy_dev_in_workspace: false) do |config|
      ws = make_workspace(config, 'sc-1', files: { '.env' => "RAILS_CADDY_DEV=1\nDEVCADDY=1\n" })
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env'))
      assert_match(/^RAILS_CADDY_DEV=1$/, content)
      assert_match(/^DEVCADDY=1$/, content)
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

  def test_port_overrides_land_in_env_not_env_local
    # .env is what compose auto-loads for variable substitution like ${WEB_PORT:-3000}.
    # .env.local is loaded via env_file: into container env only and DOES NOT reach
    # substitution. Port overrides must land in .env to take effect.
    with_dock_config do |config|
      ws = make_workspace(
        config, 'sc-1',
        files: { '.env' => '', '.env.local' => "POSTGRES_PORT=5432\nREDIS_PORT=6379\nWEB_PORT=3000\n" }
      )
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      env_content = File.read(File.join(ws, '.env'))
      env_local_content = File.read(File.join(ws, '.env.local'))

      assert_match(/^POSTGRES_PORT=0$/, env_content, '.env should pin POSTGRES_PORT=0')
      assert_match(/^REDIS_PORT=0$/, env_content,    '.env should pin REDIS_PORT=0')
      assert_match(/^WEB_PORT=0$/, env_content,      '.env should pin WEB_PORT=0')

      refute_match(/^POSTGRES_PORT=/, env_local_content, 'inherited port pins must be stripped from .env.local')
      refute_match(/^REDIS_PORT=/, env_local_content)
      refute_match(/^WEB_PORT=/, env_local_content)
    end
  end

  def test_apply_to_env_local_strips_pre_existing_gate_vars
    with_dock_config(disable_rails_caddy_dev_in_workspace: true) do |config|
      ws = make_workspace(
        config, 'sc-1',
        files: { '.env.local' => "RAILS_CADDY_DEV=1\nDEVCADDY=1\nFOO=bar\n" }
      )
      Dock::EnvFiles.apply(ws, slug: 'sc-1', config: config)
      content = File.read(File.join(ws, '.env.local'))
      refute_match(/^RAILS_CADDY_DEV=/, content)
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
