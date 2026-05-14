# frozen_string_literal: true

require_relative '../test_helper'

class Dock::ConfigTest < Minitest::Test
  def test_loads_minimal_valid_yaml_and_exposes_required_keys
    with_dock_config do |config, dir|
      assert_equal 'demoapp', config.project_name
      assert_equal 'dev.localhost', config.base_host
      assert_equal 'demoapp', config.image_name
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
      assert_match(/image_name/, error.message)
      assert_match(/db_name/, error.message)
    end
  end

  def test_derived_defaults_fall_back_to_project_name
    # Bypass with_dock_config's worktree_dir injection — we want the *raw* defaults.
    Dir.mktmpdir('ccdock-test-defaults-') do |dir|
      project_dir = File.join(dir, 'project')
      FileUtils.mkdir_p(project_dir)
      File.write(File.join(project_dir, '.dock.yml'), YAML.dump(DockTestHelpers::DEFAULT_CONFIG))
      config = Dock::Config.load(starting_path: project_dir)
      assert_equal 'demoapp', config.base_project, 'base_project defaults to project_name'
      assert_equal 'demoapp.worktrees', File.basename(config.worktree_dir_path)
      assert_equal 'demoapp_node_modules', config.node_modules_source
    end
  end

  def test_custom_worktree_dir_override_is_respected
    with_dock_config(worktree_dir: 'custom-workdir') do |config, dir|
      # worktree_dir_path is "../<worktree_dir>" relative to project_root
      expected = File.expand_path('../custom-workdir', dir)
      assert_equal expected, config.worktree_dir_path
    end
  end

  def test_custom_node_modules_source_override_is_respected
    with_dock_config(node_modules_source: 'shared_node_modules') do |config|
      assert_equal 'shared_node_modules', config.node_modules_source
    end
  end

  def test_disable_devcaddy_default_is_true
    with_dock_config do |config|
      assert config.disable_devcaddy_in_workspace?
    end
  end

  def test_disable_devcaddy_can_be_overridden_to_false
    with_dock_config(disable_devcaddy_in_workspace: false) do |config|
      refute config.disable_devcaddy_in_workspace?
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
