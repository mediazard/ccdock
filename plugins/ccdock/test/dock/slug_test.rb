# frozen_string_literal: true

require_relative '../test_helper'

class Dock::SlugTest < Minitest::Test
  def test_branch_format_extracts_ticket
    with_dock_config do |config|
      assert_equal 'sc-12345', Dock::Slug.from('user/sc-12345/feature-bar', config: config)
    end
  end

  def test_bare_ticket_passes_through
    with_dock_config do |config|
      assert_equal 'sc-12345', Dock::Slug.from('sc-12345', config: config)
    end
  end

  def test_uppercase_ticket_is_normalised
    with_dock_config do |config|
      assert_equal 'sc-12345', Dock::Slug.from('SC-12345', config: config)
    end
  end

  def test_free_form_without_ticket_normalises_to_dashed_slug
    with_dock_config do |config|
      assert_equal 'fix-the-broken-foo', Dock::Slug.from('fix the broken foo', config: config)
    end
  end

  def test_input_with_only_punctuation_falls_back_to_adj_noun
    with_dock_config do |config|
      slug = Dock::Slug.from('!!!---!!!', config: config)
      adj, noun = slug.split('-')
      assert_includes Dock::Slug::ADJECTIVES, adj, "expected adjective, got #{adj.inspect}"
      assert_includes Dock::Slug::NOUNS, noun, "expected noun, got #{noun.inspect}"
    end
  end

  def test_collision_adds_numeric_suffix
    with_dock_config do |config|
      make_workspace(config, 'sc-12345')
      assert_equal 'sc-12345-1', Dock::Slug.from('sc-12345', config: config)
    end
  end

  def test_repeated_collision_increments_suffix
    with_dock_config do |config|
      make_workspace(config, 'sc-12345')
      make_workspace(config, 'sc-12345-1')
      assert_equal 'sc-12345-2', Dock::Slug.from('sc-12345', config: config)
    end
  end

  def test_nil_input_falls_back_to_adj_noun
    with_dock_config do |config|
      slug = Dock::Slug.from(nil, config: config)
      assert_match(/\A[a-z]+-[a-z]+\z/, slug)
    end
  end

  def test_empty_input_falls_back_to_adj_noun
    with_dock_config do |config|
      slug = Dock::Slug.from('   ', config: config)
      assert_match(/\A[a-z]+-[a-z]+\z/, slug)
    end
  end

  def test_base_slug_normalises_slashes_to_dashes
    # Slashes get rewritten to dashes by the punctuation regex *before* split('/'),
    # so the whole input becomes one segment.
    assert_equal 'user-feature-bar', Dock::Slug.base_slug('user/feature-bar')
  end

  def test_base_slug_normalises_punctuation_to_dashes
    # Multi-word input with no ticket: the input lacks slashes, so the normalised
    # form (a single dashed segment with no '/') is returned verbatim.
    assert_equal 'fix-broken-thing', Dock::Slug.base_slug('Fix BROKEN thing!!')
  end

  # Security: slug validation predicates and rejection of path-traversal /
  # injection payloads. These guard the boundary between user input (or
  # tampered .dock/slug / metadata.json) and filesystem / URL / argv use.

  def test_valid_returns_true_for_safe_slugs
    assert Dock::Slug.valid?('sc-12345')
    assert Dock::Slug.valid?('happy-otter')
    assert Dock::Slug.valid?('a')
  end

  def test_valid_returns_false_for_traversal_and_unsafe_chars
    refute Dock::Slug.valid?('../etc/passwd')
    refute Dock::Slug.valid?('foo/bar')
    refute Dock::Slug.valid?('-leading-dash')
    refute Dock::Slug.valid?('UPPER')
    refute Dock::Slug.valid?('with space')
    refute Dock::Slug.valid?("nl\ninjected")
    refute Dock::Slug.valid?('')
    refute Dock::Slug.valid?(nil)
    refute Dock::Slug.valid?('a' * 64) # >63 chars
  end

  def test_validate_bang_raises_invalid_slug_error
    error = assert_raises(Dock::Slug::InvalidSlugError) { Dock::Slug.validate!('../escape') }
    assert_match(/Invalid slug/, error.message)
  end

  def test_base_slug_caps_length_to_63_chars
    long = 'a' * 200
    assert_equal 63, Dock::Slug.base_slug(long).length
  end

  def test_base_slug_neutralises_traversal_attempts
    # `../../etc` becomes a dashed segment, can never escape the workspace dir.
    refute_includes Dock::Slug.base_slug('../../etc'), '/'
    refute_includes Dock::Slug.base_slug('../../etc'), '.'
  end
end
