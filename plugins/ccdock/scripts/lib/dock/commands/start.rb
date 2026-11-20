# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Dock
  module Commands
    # `cli start [input] [--description "..."]`
    #
    # Orchestrates the full workspace creation flow:
    #   1. Derive slug + workspace path (in a linked git worktree: dock in place,
    #      slug = folder name, no worktree created, reruns skip the volume clone)
    #   2. Create worktree (or reuse if already there)
    #   3. Copy inherited dotfiles (.env, .env.local, .bundle, .claude/settings.local.json)
    #   4. Sed-mutate env files (per Dock::EnvFiles)
    #   5. Bring up postgres + redis
    #   6. Clone configured named volumes from main (clone_volumes: best-effort, default empty)
    #   7. Bring up web + worker — entrypoint runs `db:prepare`, which creates and seeds the DB
    #   8. Poll web health
    #   9. Register Caddy wildcard route at *.<slug>-<base_host>
    #  10. Write .dock/{metadata.json, fingerprint, slug}
    class Start < Base
      INHERITABLE_FILES = %w[.env .env.local .bundle .claude/settings.local.json].freeze

      def call(input = nil, description: nil)
        linked = Workspace.linked_worktree(Dir.pwd)

        if linked
          workspace_path = linked[:root]
          slug, rerun = resolve_in_place(workspace_path, input: input)
        else
          slug = Slug.from(input, config: @config)
          workspace_path = @config.workspace_path_for(slug)
          say "Preparing dock '#{slug}' at #{workspace_path}"
          provision_worktree(workspace_path)
        end

        Dir.chdir(workspace_path) do
          prepare_workspace(workspace_path, slug: slug)
          start_stack(slug, first_run: !rerun)
          web_port = resolve_web_port!(slug)
          # A rerun may find the old route pointing at a stale port.
          Caddy.delete_route(slug: slug) if linked
          Caddy.register_wildcard(slug: slug, port: web_port, config: @config)
          write_workspace_state(workspace_path, slug: slug, web_port: web_port, description: description,
                                                input: input, in_place: !linked.nil?)
        end

        announce_ready(slug)
      end

      private

      # In-place mode: the current linked worktree IS the workspace. The slug is
      # its folder name; an existing compose project from there means a rerun.
      # @return [Array(String, Boolean)] slug, rerun
      def resolve_in_place(workspace_path, input:)
        slug = Slug.from_directory(workspace_path)
        refuse_reserved!(slug)

        existing = Docker.project_working_dir(project: slug)
        if existing && !File.identical?(existing, workspace_path)
          abort_with "Slug '#{slug}' is already used by a dock at #{existing}. " \
                     "If that folder is gone, run: docker compose -p #{slug} down -v"
        end

        say "Docking in place at #{workspace_path} as '#{slug}'"
        say "  (input #{input.inspect} is ignored in a linked worktree)" unless input.to_s.strip.empty?
        # Volumes outlive `compose down`; cloning into them again would fail.
        [slug, !existing.nil? || Docker.project_volumes(project: slug).any?]
      end

      def provision_worktree(workspace_path)
        if Workspace.already_present?(workspace_path)
          say '  Worktree already present; reusing.'
        else
          Workspace.create(workspace_path)
        end
      end

      def prepare_workspace(workspace_path, slug:)
        copy_inherited_files(workspace_path)
        EnvFiles.apply(workspace_path, slug: slug, config: @config)
      end

      def start_stack(slug, first_run: true)
        bring_up_data_services(slug)
        if first_run
          clone_named_volumes(slug)
        else
          say '  Existing dock stack found; skipping volume clone.'
        end
        bring_up_app_services(slug)
        wait_for_web(slug)
      end

      # Clone main's named volumes into <slug>_<name>. Empty list (default)
      # means workspaces start with empty named volumes — relying on the image
      # build (e.g. baked-in node_modules / vendored gems) for first-run state.
      def clone_named_volumes(slug)
        @config.clone_volumes.each do |basename|
          source = "#{@config.project_name}_#{basename}"
          target = "#{slug}_#{basename}"
          Docker.try_clone_volume(from: source, to: target)
        end
      end

      def resolve_web_port!(slug)
        port = Docker.published_port(project: slug, service: 'web', container_port: 3000)
        abort_with "Could not resolve web port for '#{slug}'" if port.nil?
        port
      end

      def announce_ready(slug)
        say "Dock ready: https://app.#{slug}-#{@config.base_host}"
        say '  (replace `app` with any tenant subdomain — clients, therapists, admin, etc.)'
      end

      def copy_inherited_files(workspace_path)
        INHERITABLE_FILES.each do |relative|
          src = File.join(@config.project_root, relative)
          next unless File.exist?(src)

          dest = File.join(workspace_path, relative)
          FileUtils.mkdir_p(File.dirname(dest))
          next if File.exist?(dest)

          FileUtils.cp_r(src, dest)
          # Inherited files may contain credentials (.env, settings.local.json).
          # Tighten perms so the workspace copy isn't world-readable even if the
          # source was created with permissive perms (e.g. 0644 on Linux).
          tighten_secret_perms(dest)
        end
      end

      def tighten_secret_perms(path)
        return unless File.file?(path)

        File.chmod(0o600, path)
      rescue Errno::EPERM, Errno::EACCES
        # Non-fatal: a noisy warning is friendlier than aborting workspace setup.
        warn_line "  (warn) could not chmod 0600 #{path}"
      end

      def bring_up_data_services(slug)
        Docker.compose(project: slug, args: %w[up -d postgres redis])
      end

      def bring_up_app_services(slug)
        Docker.compose(project: slug, args: %w[up -d web worker])
      end

      def wait_for_web(slug, max_seconds: 120)
        deadline = Time.now + max_seconds
        while Time.now < deadline
          info = Docker.service_status(project: slug, service: 'web')
          return if info && info['Health'] == 'healthy'

          sleep 3
        end
        abort_with "Web did not become healthy for '#{slug}' within #{max_seconds}s"
      end

      def write_workspace_state(workspace_path, slug:, web_port:, description:, input:, in_place:) # rubocop:disable Metrics/ParameterLists
        FileUtils.mkdir_p(File.join(workspace_path, '.dock'))

        created_at = Time.now.utc.iso8601
        ticket = input.to_s[/\bsc-\d+\b/i] || slug[/\bsc-\d+\b/i]

        metadata = {
          slug: slug,
          ticket: ticket,
          description: description,
          input: input,
          url: "https://app.#{slug}-#{@config.base_host}",
          web_port: web_port,
          created_at: created_at,
          parent_dir: @config.project_root,
          workspace_path: workspace_path,
          in_place: in_place
        }
        File.write(File.join(workspace_path, @config.metadata_filename), JSON.pretty_generate(metadata))

        fingerprint = Fingerprint.compute(slug: slug, parent_dir: @config.project_root, created_at: created_at)
        Fingerprint.write(workspace_path: workspace_path, value: fingerprint, config: @config)

        File.write(File.join(workspace_path, @config.slug_marker_filename), slug)
        File.write(File.join(workspace_path, '.dock', '.gitignore'), "*\n")
      end
    end
  end
end
