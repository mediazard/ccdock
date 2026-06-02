# frozen_string_literal: true

module Dock
  # Per-workspace .env / .env.local mutation.
  #
  # When a workspace is created, its .env and .env.local are copies of main's.
  # This module rewrites a small set of keys so the workspace has its own
  # identity (COMPOSE_PROJECT_NAME, HOST_DOMAIN, etc.) and dynamic ports.
  #
  # All values come from config — no project-specific literals.
  module EnvFiles
    module_function

    # @param workspace_path [String]
    # @param slug [String]
    # @param config [Dock::Config]
    def apply(workspace_path, slug:, config:)
      apply_to_env(File.join(workspace_path, '.env'), slug: slug, config: config)
      apply_to_env_local(File.join(workspace_path, '.env.local'), slug: slug, config: config)
    end

    def apply_to_env(path, slug:, config:)
      return unless File.exist?(path)

      content = File.read(path)
      # PROJECT_NAME / WORKROOM_NAME are opt-in Rails-ish env vars — only written
      # when base_project is configured. Generic compose projects don't need them.
      if config.base_project
        content = replace_or_append(content, 'PROJECT_NAME', %("#{slug}-#{config.base_project}"))
        content = replace_or_append(content, 'WORKROOM_NAME', slug)
      end
      content = replace_or_append(content, 'COMPOSE_PROJECT_NAME', slug)
      # Port overrides MUST live in .env (compose auto-loads it for variable
      # substitution like ${WEB_PORT:-3000}). .env.local is loaded via env_file:
      # for container env only — its values don't reach compose's substitution
      # layer, so port pinning has no effect there.
      content = replace_or_append(content, 'WEB_PORT', '0')
      content = replace_or_append(content, 'POSTGRES_PORT', '0')
      content = replace_or_append(content, 'REDIS_PORT', '0')
      # Strip the Caddy-gate env var entirely. Some Rails apps use
      # `ENV.key?('RAILS_CADDY_DEV')` (older versions: `'DEVCADDY'`) to gate Caddy
      # auto-registration, which fires on ANY value (incl. "0"). The only safe way
      # to disable it is to ensure the env var is not defined in the container. We
      # strip both names so adopters on either gem version are covered.
      content = strip_rails_caddy_dev(content) if config.disable_rails_caddy_dev_in_workspace?
      File.write(path, content)
    end

    def apply_to_env_local(path, slug:, config:)
      return unless File.exist?(path)

      content = File.read(path)
      content = replace_or_append(content, 'HOST_DOMAIN', "#{slug}-#{config.base_host}")
      # Strip inherited port pins from .env.local — they wouldn't reach compose
      # substitution anyway (.env.local is container-env via env_file:, not
      # auto-loaded for substitution), but keeping them around is confusing.
      content = strip_key(content, 'POSTGRES_PORT')
      content = strip_key(content, 'REDIS_PORT')
      content = strip_key(content, 'WEB_PORT')
      content = strip_rails_caddy_dev(content) if config.disable_rails_caddy_dev_in_workspace?
      File.write(path, content)
    end

    # Strip both the current (RAILS_CADDY_DEV) and legacy (DEVCADDY) gate keys.
    RAILS_CADDY_DEV_KEYS = %w[RAILS_CADDY_DEV DEVCADDY].freeze

    def strip_rails_caddy_dev(content)
      RAILS_CADDY_DEV_KEYS.reduce(content) { |acc, key| strip_key(acc, key) }
    end

    def strip_key(content, key)
      content.gsub(/^#{Regexp.escape(key)}=.*\n?/, '')
    end

    # If a line `KEY=...` exists, replace its value. Otherwise append `KEY=value`.
    def replace_or_append(content, key, value)
      pattern = /^#{Regexp.escape(key)}=.*$/
      replacement = "#{key}=#{value}"
      if content.match?(pattern)
        content.sub(pattern, replacement)
      else
        "#{content.chomp}\n#{replacement}\n"
      end
    end
  end
end
