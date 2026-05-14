# frozen_string_literal: true

require 'fileutils'
require 'json'

module Dock
  module Commands
    # `cli destroy <slug>` — tear down a dock workspace's runtime artifacts.
    #
    # Removes: containers, scoped Docker volumes (incl. node_modules created outside compose),
    # Caddy wildcard route, inbox file. Leaves the workspace dir + jj workspace registration
    # in place — user runs `jj workspace forget` themselves to fully reclaim disk.
    #
    # Safety: refuses reserved slugs, refuses if fingerprint mismatches, refuses if any volume
    # would touch main's project (volume names must start with `<slug>_`).
    class Destroy < Base
      def call(slug)
        abort_with "Invalid slug #{slug.inspect}" unless Slug.valid?(slug)

        workspace_path = @config.workspace_path_for(slug)
        abort_with "Workspace for '#{slug}' not found at #{workspace_path}" unless File.directory?(workspace_path)

        refuse_reserved!(slug)

        metadata_file = File.join(workspace_path, @config.metadata_filename)
        unless File.exist?(metadata_file)
          abort_with "Refusing: #{metadata_file} missing — workspace not managed by dock."
        end

        metadata = JSON.parse(File.read(metadata_file))
        Fingerprint.verify!(workspace_path: workspace_path, metadata: metadata, config: @config)

        guard_volumes!(slug)

        Docker.compose(project: slug, args: %w[down -v])
        # node_modules volume is created outside compose by Docker.clone_volume,
        # so `compose down -v` won't catch it. Remove explicitly.
        system('docker', 'volume', 'rm', "#{slug}_node_modules", out: File::NULL, err: File::NULL)

        Caddy.delete_route(slug: slug)
        Inbox.remove(slug: slug, config: @config)

        say "Dock '#{slug}' destroyed. Workspace dir left at #{workspace_path}; " \
            'run `jj workspace forget` (or `git worktree remove`) separately.'
      end

      private

      def refuse_reserved!(slug)
        reserved = @config.reserved_slugs + [@config.project_name, @config.base_project]
        return unless reserved.include?(slug)

        abort_with "Refusing: '#{slug}' is reserved (main project name or in reserved_slugs)."
      end

      def guard_volumes!(slug)
        volumes = Docker.project_volumes(project: slug)
        bad = volumes.reject { |v| v.start_with?("#{slug}_") }
        return if bad.empty?

        abort_with "Refusing: volumes do not all start with '#{slug}_': #{bad.join(', ')}"
      end
    end
  end
end
