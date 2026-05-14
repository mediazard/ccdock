# frozen_string_literal: true

require 'json'
require 'time'

module Dock
  module Commands
    # `cli list` — render a table of active docks.
    #
    # Source of truth is two-layered:
    #   - Docker daemon (`docker compose ls`) tells us what compose projects exist
    #   - Workspace's .dock/metadata.json tells us which projects are docks (vs unrelated compose stacks)
    #
    # Status comes from the inbox (last event written by the worker's Notification/Stop hook).
    class List < Base
      HEADERS = %w[SLUG STATUS URL TICKET AGE].freeze

      def call
        rows = build_rows
        if rows.empty?
          say 'No active docks. Create one with /dock <input>.'
          return
        end

        say render_table(rows)
      end

      private

      def build_rows
        Docker.list_projects.each_with_object([]) do |project, acc|
          slug = project['Name']
          # Skip any compose project whose name is not a valid dock slug.
          # Docker permits chars (e.g. `_`) that our slug regex rejects; without
          # this guard, status_for -> Inbox.path_for would raise InvalidSlugError
          # downstream and crash the whole list.
          next unless Slug.valid?(slug)

          workspace_path = @config.workspace_path_for(slug)
          metadata_file = File.join(workspace_path, @config.metadata_filename)
          next unless File.exist?(metadata_file)

          metadata = JSON.parse(File.read(metadata_file))
          acc << [
            slug,
            status_for(slug),
            metadata['url'] || '—',
            metadata['ticket'] || '—',
            age(metadata['created_at'])
          ]
        rescue JSON::ParserError
          # Skip workspaces with corrupt metadata — surface via list, but don't crash.
          acc << [slug, 'corrupt', '—', '—', '—']
        end
      end

      def status_for(slug)
        event = Inbox.last_event(slug: slug, config: @config)
        return '—' if event.nil?

        event.fetch('event', '—')
      end

      def age(timestamp)
        return '—' if timestamp.nil?

        seconds = (Time.now - Time.iso8601(timestamp)).to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      rescue ArgumentError
        '—'
      end

      def render_table(rows)
        widths = column_widths([HEADERS] + rows)
        lines = []
        lines << format_row(HEADERS, widths)
        lines << format_row(widths.map { |w| '-' * w }, widths)
        rows.each { |row| lines << format_row(row, widths) }
        lines.join("\n")
      end

      def column_widths(all_rows)
        HEADERS.each_with_index.map do |_h, i|
          all_rows.map { |row| (row[i] || '').to_s.length }.max
        end
      end

      def format_row(row, widths)
        row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join('  ')
      end
    end
  end
end
