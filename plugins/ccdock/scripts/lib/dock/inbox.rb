# frozen_string_literal: true

require 'fileutils'
require 'json'

module Dock
  # Inbox where worker Claude sessions write events (via the Notification/Stop hooks).
  #
  # File location: ~/.claude/docks/inbox/<slug>.jsonl
  # Format: one JSON object per line — { ts, slug, event: "question"|"idle", hook, message }
  #
  # The captain reads `last_event` to render status in /docks.
  module Inbox
    module_function

    def path_for(slug:, config:)
      Slug.validate!(slug)
      File.join(config.inbox_dir, "#{slug}.jsonl")
    end

    def ensure_dir(config:)
      FileUtils.mkdir_p(config.inbox_dir)
    end

    def remove(slug:, config:)
      FileUtils.rm_f(path_for(slug: slug, config: config))
    end

    # Returns the parsed JSON of the most recent line, or nil if no inbox / empty.
    def last_event(slug:, config:)
      file = path_for(slug: slug, config: config)
      return nil unless File.exist?(file)

      last_line = File.foreach(file).reduce(nil) { |_acc, line| line.strip.empty? ? nil : line }
      return nil unless last_line

      JSON.parse(last_line)
    rescue JSON::ParserError
      nil
    end
  end
end
