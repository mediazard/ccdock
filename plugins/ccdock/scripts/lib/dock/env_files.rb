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
      content = replace_or_append(content, 'PROJECT_NAME', %("#{slug}-#{config.base_project}"))
      content = replace_or_append(content, 'COMPOSE_PROJECT_NAME', slug)
      content = replace_or_append(content, 'WORKROOM_NAME', slug)
      # Strip DEVCADDY entirely. Some Rails apps use `ENV.key?('DEVCADDY')` to gate
      # Caddy auto-registration, which fires on ANY value (incl. "0"). The only safe
      # way to disable it is to ensure the env var is not defined in the container.
      content = strip_key(content, 'DEVCADDY') if config.disable_devcaddy_in_workspace?
      File.write(path, content)
    end

    def apply_to_env_local(path, slug:, config:)
      return unless File.exist?(path)

      content = File.read(path)
      content = replace_or_append(content, 'HOST_DOMAIN', "#{slug}-#{config.base_host}")
      content = replace_or_append(content, 'POSTGRES_PORT', '0')
      content = replace_or_append(content, 'REDIS_PORT', '0')
      content = strip_key(content, 'DEVCADDY') if config.disable_devcaddy_in_workspace?
      File.write(path, content)
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
