# frozen_string_literal: true

require 'digest'

module Dock
  # Workspace fingerprint — guards against destroy operating on a hand-edited workspace.
  #
  # SHA256("<slug>|<parent_dir>|<created_at>"). Computed at setup, stored in
  # .dock/fingerprint, recomputed at destroy and compared. Any tamper (e.g. someone
  # edited .env to change COMPOSE_PROJECT_NAME) breaks the fingerprint.
  module Fingerprint
    module_function

    def compute(slug:, parent_dir:, created_at:)
      Digest::SHA256.hexdigest("#{slug}|#{parent_dir}|#{created_at}")
    end

    def write(workspace_path:, value:, config:)
      path = File.join(workspace_path, config.fingerprint_filename)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, value)
    end

    def read(workspace_path:, config:)
      path = File.join(workspace_path, config.fingerprint_filename)
      return nil unless File.exist?(path)

      File.read(path).strip
    end

    def verify!(workspace_path:, metadata:, config:)
      stored = read(workspace_path: workspace_path, config: config)
      raise Error, 'Refusing: .dock/fingerprint missing — workspace not managed by dock.' if stored.nil?

      expected = compute(
        slug: metadata.fetch('slug'),
        parent_dir: metadata.fetch('parent_dir'),
        created_at: metadata.fetch('created_at')
      )
      return if stored == expected

      raise Error, 'Refusing: fingerprint mismatch — workspace was modified outside dock.'
    end
  end
end

require 'fileutils'
