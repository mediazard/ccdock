# frozen_string_literal: true

module Dock
  module Commands
    # Shared behaviour for every command:
    #   - eager-loads Dock::Config from current cwd (walks up to find .dock.yml)
    #   - exposes #say / #abort_with helpers for consistent CLI output
    #
    # Each command is a plain Ruby class with a #call method. The Thor entrypoint
    # constructs the right command and invokes #call.
    class Base
      attr_reader :config

      def initialize(config: Dock::Config.load)
        @config = config
      end

      def call(*)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      protected

      def say(message)
        $stdout.puts(message)
      end

      def warn_line(message)
        warn(message)
      end

      def abort_with(message)
        warn(message)
        exit 1
      end

      # Where a dock's workspace lives: the directory its compose project was
      # started from (covers in-place docks), else the configured worktree dir.
      def dock_workspace_path(slug)
        Docker.project_working_dir(project: slug) || @config.workspace_path_for(slug)
      end

      def refuse_reserved!(slug)
        reserved = (@config.reserved_slugs + [@config.project_name, @config.base_project]).compact
        return unless reserved.include?(slug)

        abort_with "Refusing: '#{slug}' is reserved (main project name or in reserved_slugs)."
      end
    end
  end
end
