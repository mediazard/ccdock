# frozen_string_literal: true

# Test harness for the ccdock plugin.
#
# Runtime dependencies (install with `gem install mocha webmock minitest`):
#   - minitest   (assertion framework)
#   - mocha      (method stubbing — matches Rails app conventions)
#   - webmock    (HTTP stubbing for Caddy admin API)
#
# Layout: every Ruby module in scripts/lib/dock has a 1:1 matching test under
# test/dock/. Bash scripts under scripts/ have matching .bats files at the
# top of test/. The runner test/run_tests.sh wires both together.

require 'minitest/autorun'
require 'mocha/minitest'
require 'webmock/minitest'

require 'fileutils'
require 'json'
require 'tmpdir'
require 'tempfile'
require 'yaml'

# Make the plugin's lib/ importable. Tests use `require 'dock/<module>'`.
PLUGIN_ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(PLUGIN_ROOT, 'scripts', 'lib'))

require 'dock'

# Disallow real HTTP in every test — Caddy tests opt in via WebMock stubs.
WebMock.disable_net_connect!

module DockTestHelpers
  DEFAULT_CONFIG = {
    'project_name' => 'demoapp',
    'base_host' => 'dev.localhost',
    'db_name' => 'demoapp_development',
    'db_user' => 'postgres',
    'db_service' => 'postgres'
  }.freeze

  # Yields a Dock::Config rooted in a fresh tmp directory containing a .dock.yml.
  # Additional overrides are merged into DEFAULT_CONFIG before serialisation.
  #
  # Test isolation: by default, worktree_dir is forced to a path inside the
  # per-test tmpdir so collision/workspace tests don't bleed into each other
  # (Dock::Config's default worktree_dir lives at "../<dir>", which would be
  # the shared system tmp root). Override `worktree_dir:` to test the default.
  #
  #   with_dock_config(project_name: 'foo') { |config, dir| ... }
  def with_dock_config(**overrides)
    Dir.mktmpdir('ccdock-test-') do |outer|
      project_dir = File.join(outer, 'project')
      FileUtils.mkdir_p(project_dir)
      # worktree_dir_path is expanded relative to "../" of project_root, so
      # placing the worktree dir at <outer>/<name> keeps everything sandboxed.
      payload = { 'worktree_dir' => 'worktrees' }
                .merge(DEFAULT_CONFIG)
                .merge(overrides.transform_keys(&:to_s))
      File.write(File.join(project_dir, '.dock.yml'), YAML.dump(payload))
      config = Dock::Config.load(starting_path: project_dir)
      yield config, project_dir
    end
  end

  # Make a workspace path under config.worktree_dir_path containing whatever
  # files the block writes. Returns the path.
  def make_workspace(config, slug, files: {})
    FileUtils.mkdir_p(config.worktree_dir_path)
    path = config.workspace_path_for(slug)
    FileUtils.mkdir_p(path)
    files.each do |relative, content|
      target = File.join(path, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content)
    end
    path
  end
end

module Minitest
  class Test
    include DockTestHelpers
  end
end
