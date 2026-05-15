# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'time'

module Dock
  module Commands
    # `cli start <input> [--description "..."]`
    #
    # Orchestrates the full workspace creation flow:
    #   1. Validate dump file exists
    #   2. Derive slug + workspace path
    #   3. Create worktree (or reuse if already there)
    #   4. Copy inherited dotfiles (.env, .env.local, .bundle, .claude/settings.local.json)
    #   5. Sed-mutate env files (per Dock::EnvFiles)
    #   6. Bring up postgres + redis, restore dump
    #   7. Clone configured named volumes from main (clone_volumes: best-effort, default empty)
    #   8. Bring up web + worker — entrypoint runs `db:prepare` automatically
    #   9. Poll web health
    #  10. Register Caddy wildcard route at *.<slug>-<base_host>
    #  11. Write .dock/{metadata.json, fingerprint, slug}
    class Start < Base
      INHERITABLE_FILES = %w[.env .env.local .bundle .claude/settings.local.json].freeze

      def call(input, description: nil)
        ensure_dump_present!
        slug = Slug.from(input, config: @config)
        workspace_path = @config.workspace_path_for(slug)
        say "Preparing dock '#{slug}' at #{workspace_path}"

        provision_worktree(workspace_path)
        Dir.chdir(workspace_path) do
          prepare_workspace(workspace_path, slug: slug)
          start_stack(slug)
          web_port = resolve_web_port!(slug)
          Caddy.register_wildcard(slug: slug, port: web_port, config: @config)
          write_workspace_state(workspace_path, slug: slug, web_port: web_port, description: description, input: input)
        end

        announce_ready(slug)
      end

      private

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

      def start_stack(slug)
        bring_up_data_services(slug)
        wait_for_postgres(slug)
        restore_dump(slug)
        clone_named_volumes(slug)
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

      def ensure_dump_present!
        return if File.exist?(@config.dump_path)

        abort_with 'Run /dock-dump first to prepare the workspace seed. ' \
                   "Expected at: #{@config.dump_path}"
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

      def wait_for_postgres(slug, max_seconds: 60)
        deadline = Time.now + max_seconds
        while Time.now < deadline
          info = Docker.service_status(project: slug, service: @config.db_service)
          return if info && info['Health'] == 'healthy'

          sleep 2
        end
        abort_with "Postgres did not become healthy for '#{slug}' within #{max_seconds}s"
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

      def restore_dump(slug)
        Slug.validate!(slug)

        # Workspace's postgres image init creates only the default 'postgres' DB.
        # The dump (made via `pg_dump --no-owner --no-acl`) doesn't include CREATE DATABASE,
        # so we createdb first. Idempotent — failure (DB already exists) is tolerated.
        system(
          'docker', 'compose', '-p', slug, 'exec', '-T', @config.db_service,
          'createdb', '-U', @config.db_user, @config.db_name,
          out: File::NULL, err: File::NULL
        )

        run_dump_pipeline!(slug)
      end

      # Stream gunzip -> docker compose exec psql via Open3.pipeline. All commands
      # are argv arrays — no shell, no quoting, no injection surface even if
      # dump_path / db_user / db_name ever contained shell metacharacters.
      # Extracted from #restore_dump so tests can stub it.
      def run_dump_pipeline!(slug)
        statuses = Open3.pipeline(
          ['gunzip', '-c', @config.dump_path],
          ['docker', 'compose', '-p', slug, 'exec', '-T', @config.db_service,
           'psql', '-U', @config.db_user, '-v', 'ON_ERROR_STOP=1',
           '-d', @config.db_name],
          out: File::NULL, err: File::NULL
        )
        return if statuses.all?(&:success?)

        abort_with "Dump restore failed for '#{slug}'"
      end

      def write_workspace_state(workspace_path, slug:, web_port:, description:, input:)
        FileUtils.mkdir_p(File.join(workspace_path, '.dock'))

        created_at = Time.now.utc.iso8601
        ticket = input.to_s[/\bsc-\d+\b/i]

        metadata = {
          slug: slug,
          ticket: ticket,
          description: description,
          input: input,
          url: "https://app.#{slug}-#{@config.base_host}",
          web_port: web_port,
          created_at: created_at,
          parent_dir: @config.project_root,
          workspace_path: workspace_path
        }
        File.write(File.join(workspace_path, @config.metadata_filename), JSON.pretty_generate(metadata))

        fingerprint = Fingerprint.compute(slug: slug, parent_dir: @config.project_root, created_at: created_at)
        Fingerprint.write(workspace_path: workspace_path, value: fingerprint, config: @config)

        File.write(File.join(workspace_path, @config.slug_marker_filename), slug)
      end
    end
  end
end
