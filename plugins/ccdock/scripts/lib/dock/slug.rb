# frozen_string_literal: true

require 'securerandom'

module Dock
  # Slug derivation for a new dock.
  #
  # Inputs handled:
  #   "user/sc-12345/feature-bar"  → "sc-12345"   (Shortcut branch format)
  #   "sc-12345"                   → "sc-12345"   (bare ticket)
  #   "fix the broken foo"         → "happy-otter" (adj-noun fallback)
  #
  # Collision: if <worktree_dir>/sc-12345 already exists, returns "sc-12345-1".
  module Slug
    ADJECTIVES = %w[happy swift brave calm eager bright keen bold cosy lively].freeze
    NOUNS = %w[otter falcon badger lynx raven fox heron stoat marten ibis].freeze
    TICKET_PATTERN = /\b(sc-\d+)\b/i
    SLUG_CHARS = /\A[a-z0-9][a-z0-9-]{0,62}\z/

    class InvalidSlugError < Dock::Error; end

    module_function

    # Predicate: does `value` match our filesystem-safe slug shape?
    # Defense-in-depth — called wherever a slug arrives from a non-Slug source
    # (CLI argv, .dock/slug on disk, metadata.json).
    def valid?(value)
      value.is_a?(String) && SLUG_CHARS.match?(value)
    end

    # Raises InvalidSlugError unless the string is a safe slug. Use at the
    # boundary of every path/URL/compose-project construction.
    def validate!(value)
      return value if valid?(value)

      raise InvalidSlugError,
            "Invalid slug #{value.inspect} — must match #{SLUG_CHARS.source} (lowercase, digits, dashes; ≤63 chars)."
    end

    # @param input [String] user-provided branch/ticket/description
    # @param config [Dock::Config]
    # @return [String] a unique, filesystem-safe slug
    def from(input, config:)
      base = base_slug(input)
      validate!(base)
      ensure_unique(base, config: config)
    end

    def base_slug(input)
      return adj_noun if input.nil? || input.strip.empty?

      if (match = TICKET_PATTERN.match(input))
        return match[1].downcase
      end

      normalized = input.downcase.strip.gsub(/[^a-z0-9-]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
      normalized = normalized[0, 63] # cap length for filesystem/compose-project safety
      return adj_noun if normalized.empty? || normalized !~ SLUG_CHARS

      normalized
    end

    def adj_noun
      "#{ADJECTIVES.sample}-#{NOUNS.sample}"
    end

    def ensure_unique(base, config:)
      candidate = base
      suffix = 1
      while File.exist?(config.workspace_path_for(candidate))
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end
      candidate
    end
  end
end
