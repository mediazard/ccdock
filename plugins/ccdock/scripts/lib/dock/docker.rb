# frozen_string_literal: true

require 'json'
require 'open3'

module Dock
  # Docker / compose helpers used by start, destroy, list.
  module Docker
    module_function

    # @param from [String] source volume name
    # @param to [String] target volume name (created if missing)
    # @return [Symbol] :cloned if cloned, :source_missing if source volume absent
    def try_clone_volume(from:, to:)
      return :source_missing unless volume_exists?(from)

      system('docker', 'volume', 'create', to, out: File::NULL, err: File::NULL)
      ok = system(
        'docker', 'run', '--rm',
        '-v', "#{from}:/from",
        '-v', "#{to}:/to",
        'alpine', 'cp', '-a', '/from/.', '/to/',
        out: File::NULL, err: File::NULL
      )
      raise Error, "Failed to clone volume #{from} → #{to}" unless ok

      :cloned
    end

    def volume_exists?(name)
      out, _err, status = Open3.capture3(
        'docker', 'volume', 'ls', '--format', '{{.Name}}', '--filter', "name=^#{name}$"
      )
      return false unless status.success?

      out.split("\n").map(&:strip).include?(name)
    end

    # @return [Array<String>] volume names belonging to the given compose project
    def project_volumes(project:)
      out, _err, status = Open3.capture3(
        'docker', 'volume', 'ls', '--format', '{{.Name}}',
        '--filter', "label=com.docker.compose.project=#{project}"
      )
      return [] unless status.success?

      out.split("\n").map(&:strip).reject(&:empty?)
    end

    # @return [Integer, nil] dynamic host port mapped to <service>:<container_port>
    def published_port(project:, service:, container_port:)
      out, _err, status = Open3.capture3(
        'docker', 'compose', '-p', project, 'port', service, container_port.to_s
      )
      return nil unless status.success?

      out.strip.split(':').last&.to_i
    end

    # Run `docker compose -p <project> <args...>`. Inherits stdio.
    def compose(project:, args:, env: {})
      cleaned_env = clean_env.merge(env)
      ok = system(cleaned_env, 'docker', 'compose', '-p', project, *args)
      raise Error, "docker compose -p #{project} #{args.join(' ')} failed" unless ok
    end

    # docker compose ps <service> --format json — returns parsed hash or nil.
    def service_status(project:, service:)
      out, _err, status = Open3.capture3(
        'docker', 'compose', '-p', project, 'ps', service, '--format', 'json'
      )
      return nil unless status.success? && !out.strip.empty?

      # Compose may emit a single object or an array; normalise to one hash.
      first_line = out.lines.find { |line| line.strip.start_with?('{', '[') }
      return nil unless first_line

      parsed = JSON.parse(first_line)
      parsed.is_a?(Array) ? parsed.first : parsed
    rescue JSON::ParserError
      nil
    end

    # @return [Array<Hash>] all compose projects on the host
    def list_projects
      out, _err, status = Open3.capture3('docker', 'compose', 'ls', '--format', 'json')
      return [] unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError
      []
    end

    # Strip shell-inherited env vars that would override workspace .env settings.
    # Without this, a shell that previously ran main's compose (which exports
    # POSTGRES_PORT=5432, etc.) would force the workspace to bind those ports too.
    PROBLEMATIC_VARS = %w[POSTGRES_PORT REDIS_PORT WEB_PORT RAILS_CADDY_DEV DEVCADDY].freeze

    def clean_env
      PROBLEMATIC_VARS.to_h { |k| [k, nil] }
    end
    private_class_method :clean_env
  end
end
