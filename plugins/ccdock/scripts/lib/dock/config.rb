# frozen_string_literal: true

require 'yaml'
require 'pathname'

module Dock
  # Loads .dock.yml from the project root.
  #
  # Discovery: walks up from cwd until .dock.yml is found, or the filesystem
  # root is hit. Caches the loaded config per process.
  #
  # Adopting projects place a .dock.yml with at minimum:
  #   project_name: <main compose project name>
  #   base_host: <e.g. dev.localhost>
  #   image_name: <docker image name>
  #   db_name: <database to dump/restore>
  #
  # See .dock.example.yml for the full schema.
  class Config
    REQUIRED_KEYS = %w[project_name base_host image_name db_name].freeze

    DEFAULTS = {
      'base_project' => nil,            # defaults to project_name if unset
      'db_user' => 'postgres',
      'db_service' => 'postgres',
      'dump_path' => 'tmp/dock-dump.sql.gz',
      'worktree_dir' => nil,            # defaults to "<project_name>.worktrees"
      'node_modules_source' => nil,     # defaults to "<project_name>_node_modules"
      'reserved_slugs' => [],
      'disable_devcaddy_in_workspace' => true,
      'inbox_dir' => '~/.claude/docks/inbox'
    }.freeze

    class << self
      def load(starting_path: Dir.pwd)
        root = find_project_root(starting_path)
        path = File.join(root, '.dock.yml')
        raw = YAML.safe_load_file(path, permitted_classes: []) || {}
        new(raw, project_root: root)
      end

      def find_project_root(starting_path)
        path = Pathname.new(starting_path).expand_path
        path.ascend do |candidate|
          return candidate.to_s if candidate.join('.dock.yml').file?
        end
        raise ConfigNotFoundError,
              "No .dock.yml found walking up from #{starting_path}. Add one at your project root."
      end
    end

    attr_reader :project_root

    def initialize(raw, project_root:)
      @raw = DEFAULTS.merge(raw || {})
      @project_root = project_root
      validate!
      apply_derived_defaults!
    end

    def project_name = fetch('project_name')
    def base_host = fetch('base_host')
    def base_project = fetch('base_project')
    def image_name = fetch('image_name')
    def db_name = fetch('db_name')
    def db_user = fetch('db_user')
    def db_service = fetch('db_service')
    def dump_path = File.join(@project_root, safe_relative('dump_path'))
    def worktree_dir = fetch('worktree_dir')
    def worktree_dir_path = File.expand_path("../#{safe_relative('worktree_dir')}", @project_root)
    def node_modules_source = fetch('node_modules_source')
    def reserved_slugs = Array(fetch('reserved_slugs'))
    def disable_devcaddy_in_workspace? = fetch('disable_devcaddy_in_workspace') == true
    def inbox_dir = File.expand_path(fetch('inbox_dir'))

    # Path inside a workspace where the slug marker lives — read by notify hook
    # to identify whether the current cwd is a dock workspace.
    def slug_marker_filename = '.dock/slug'

    # Path inside a workspace where the fingerprint lives — used by destroy to
    # verify the workspace wasn't tampered with.
    def fingerprint_filename = '.dock/fingerprint'

    # Path inside a workspace where metadata lives.
    def metadata_filename = '.dock/metadata.json'

    def workspace_path_for(slug)
      File.join(worktree_dir_path, slug)
    end

    private

    def fetch(key)
      @raw.fetch(key) { raise ConfigInvalidError, "Missing config key: #{key}" }
    end

    # Defense in depth: configured relative paths must stay relative and may
    # not contain `..` segments. Prevents a hand-edited .dock.yml from
    # redirecting workspace creation or dump writes outside the project tree.
    def safe_relative(key)
      value = fetch(key).to_s
      raise ConfigInvalidError, "#{key} must be a relative path, got #{value.inspect}" if value.start_with?('/')

      segments = value.split(File::SEPARATOR)
      if segments.include?('..')
        raise ConfigInvalidError, "#{key} may not contain '..' segments, got #{value.inspect}"
      end

      value
    end

    def validate!
      missing = REQUIRED_KEYS.reject { |k| @raw[k].is_a?(String) && !@raw[k].empty? }
      return if missing.empty?

      raise ConfigInvalidError,
            "#{File.join(@project_root, '.dock.yml')} is missing required keys: #{missing.join(', ')}"
    end

    def apply_derived_defaults!
      @raw['base_project'] ||= @raw['project_name']
      @raw['worktree_dir'] ||= "#{@raw['project_name']}.worktrees"
      @raw['node_modules_source'] ||= "#{@raw['project_name']}_node_modules"
    end
  end
end
