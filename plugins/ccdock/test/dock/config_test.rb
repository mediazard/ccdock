# frozen_string_literal: true

require_relative '../test_helper'

class Dock::ConfigTest < Minitest::Test
  def test_loads_minimal_valid_yaml_and_exposes_required_keys
    with_dock_config do |config, dir|
      assert_equal 'demoapp', config.project_name
      assert_equal 'dev.localhost', config.base_host
      assert_equal 'demoapp_development', config.db_name
      assert_equal dir, config.project_root
    end
  end

  def test_raises_when_no_dock_yml_anywhere_up_the_tree
    Dir.mktmpdir('ccdock-test-empty-') do |dir|
      error = assert_raises(Dock::ConfigNotFoundError) do
        Dock::Config.load(starting_path: dir)
      end
      assert_match(/No \.dock\.yml found/, error.message)
    end
  end

  def test_raises_when_required_keys_are_missing
    Dir.mktmpdir('ccdock-test-bad-') do |dir|
      File.write(File.join(dir, '.dock.yml'), YAML.dump('project_name' => 'foo'))
      error = assert_raises(Dock::ConfigInvalidError) do
        Dock::Config.load(starting_path: dir)
      end
      assert_match(/missing required keys/, error.message)
      assert_match(/base_host/, error.message)
      assert_match(/db_name/, error.message)
    end
  end

  def test_image_name_is_no_longer_required_or_exposed
    # image_name was a v0.1.0 required key that was never read by any code.
    # v0.2.0 drops it from REQUIRED_KEYS and removes the accessor.
    refute_includes Dock::Config::REQUIRED_KEYS, 'image_name'
  end

  def test_derived_defaults
    # Bypass with_dock_config's worktree_dir injection — we want the *raw* defaults.
    Dir.mktmpdir('ccdock-test-defaults-') do |dir|
      project_dir = File.join(dir, 'project')
      FileUtils.mkdir_p(project_dir)
      File.write(File.join(project_dir, '.dock.yml'), YAML.dump(DockTestHelpers::DEFAULT_CONFIG))
      config = Dock::Config.load(starting_path: project_dir)
      assert_nil config.base_project, 'base_project is nil unless explicitly set'
      assert_equal 'demoapp.worktrees', File.basename(config.worktree_dir_path)
      assert_equal [], config.clone_volumes, 'clone_volumes defaults to empty (generic-first)'
    end
  end

  def test_base_project_is_returned_verbatim_when_set
    with_dock_config(base_project: 'my-rails-app') do |config|
      assert_equal 'my-rails-app', config.base_project
    end
  end

  def test_custom_worktree_dir_override_is_respected
    with_dock_config(worktree_dir: 'custom-workdir') do |config, dir|
      # worktree_dir_path is "../<worktree_dir>" relative to project_root
      expected = File.expand_path('../custom-workdir', dir)
      assert_equal expected, config.worktree_dir_path
    end
  end

  def test_clone_volumes_returns_array_of_basenames
    with_dock_config(clone_volumes: %w[node_modules bundle_cache]) do |config|
      assert_equal %w[node_modules bundle_cache], config.clone_volumes
    end
  end

  def test_clone_volumes_rejects_empty_strings_and_coerces_to_string
    with_dock_config(clone_volumes: ['node_modules', '', nil]) do |config|
      assert_equal ['node_modules'], config.clone_volumes
    end
  end

  def test_disable_rails_caddy_dev_default_is_false
    # Generic-first: Rails-specific niceties are opt-in.
    with_dock_config do |config|
      refute config.disable_rails_caddy_dev_in_workspace?
    end
  end

  def test_disable_rails_caddy_dev_can_be_overridden_to_true
    with_dock_config(disable_rails_caddy_dev_in_workspace: true) do |config|
      assert config.disable_rails_caddy_dev_in_workspace?
    end
  end

  def test_legacy_disable_devcaddy_key_still_enables_stripping
    # Old .dock.yml files used disable_devcaddy_in_workspace before the gem
    # renamed its gate var. The legacy key maps onto the current accessor.
    with_dock_config(disable_devcaddy_in_workspace: true) do |config|
      assert config.disable_rails_caddy_dev_in_workspace?
    end
  end

  def test_current_key_wins_over_legacy_alias_when_both_present
    Dir.mktmpdir('ccdock-test-alias-') do |dir|
      File.write(
        File.join(dir, '.dock.yml'),
        YAML.dump(
          DockTestHelpers::DEFAULT_CONFIG.merge(
            'disable_devcaddy_in_workspace' => true,
            'disable_rails_caddy_dev_in_workspace' => false
          )
        )
      )
      config = Dock::Config.load(starting_path: dir)
      refute config.disable_rails_caddy_dev_in_workspace?, 'current key must take precedence over legacy alias'
    end
  end

  def test_inbox_dir_is_expanded
    with_dock_config(inbox_dir: '~/.claude/docks/inbox') do |config|
      refute_match(/^~/, config.inbox_dir)
      assert_match(%r{/\.claude/docks/inbox\z}, config.inbox_dir)
    end
  end

  def test_dump_path_is_resolved_under_project_root
    with_dock_config do |config, dir|
      assert_equal File.join(dir, 'tmp/dock-dump.sql.gz'), config.dump_path
    end
  end

  def test_workspace_path_for_joins_worktree_dir_and_slug
    with_dock_config do |config|
      assert_equal File.join(config.worktree_dir_path, 'sc-1'), config.workspace_path_for('sc-1')
    end
  end

  def test_marker_filenames_are_stable
    with_dock_config do |config|
      assert_equal '.dock/slug', config.slug_marker_filename
      assert_equal '.dock/fingerprint', config.fingerprint_filename
      assert_equal '.dock/metadata.json', config.metadata_filename
    end
  end

  def test_rejects_worktree_dir_with_parent_traversal
    Dir.mktmpdir('ccdock-test-bad-worktree-') do |dir|
      File.write(
        File.join(dir, '.dock.yml'),
        YAML.dump(DockTestHelpers::DEFAULT_CONFIG.merge('worktree_dir' => '../../etc'))
      )
      config = Dock::Config.load(starting_path: dir)
      error = assert_raises(Dock::ConfigInvalidError) { config.worktree_dir_path }
      assert_match(/may not contain '\.\.'/, error.message)
    end
  end

  def test_rejects_absolute_dump_path
    Dir.mktmpdir('ccdock-test-bad-dump-') do |dir|
      File.write(
        File.join(dir, '.dock.yml'),
        YAML.dump(DockTestHelpers::DEFAULT_CONFIG.merge('dump_path' => '/etc/passwd'))
      )
      config = Dock::Config.load(starting_path: dir)
      error = assert_raises(Dock::ConfigInvalidError) { config.dump_path }
      assert_match(/must be a relative path/, error.message)
    end
  end

  def test_finds_dock_yml_by_walking_up_from_a_subdirectory
    Dir.mktmpdir('ccdock-test-walk-') do |dir|
      File.write(File.join(dir, '.dock.yml'), YAML.dump(DockTestHelpers::DEFAULT_CONFIG))
      nested = File.join(dir, 'a', 'b', 'c')
      FileUtils.mkdir_p(nested)
      config = Dock::Config.load(starting_path: nested)
      assert_equal File.realpath(dir), File.realpath(config.project_root)
    end
  end
end
