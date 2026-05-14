# frozen_string_literal: true

require_relative '../../test_helper'

class Dock::Commands::ListTest < Minitest::Test
  def test_prints_empty_message_when_no_compose_projects
    with_dock_config do |config|
      Dock::Docker.stubs(:list_projects).returns([])
      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      assert_match(/No active docks/, out)
    end
  end

  def test_skips_compose_projects_without_dock_metadata
    with_dock_config do |config|
      Dock::Docker.stubs(:list_projects).returns([{ 'Name' => 'unrelated-compose-stack' }])
      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      assert_match(/No active docks/, out)
    end
  end

  def test_renders_header_and_row_for_dock_with_valid_metadata
    with_dock_config do |config|
      slug = 'sc-1'
      metadata = {
        'slug' => slug,
        'url' => "https://app.#{slug}-dev.localhost",
        'ticket' => 'sc-1',
        'created_at' => (Time.now - 90).utc.iso8601
      }
      make_workspace(config, slug, files: { config.metadata_filename => JSON.pretty_generate(metadata) })
      Dock::Docker.stubs(:list_projects).returns([{ 'Name' => slug }])
      Dock::Inbox.stubs(:last_event).returns({ 'event' => 'question' })

      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      Dock::Commands::List::HEADERS.each { |h| assert_includes out, h }
      assert_includes out, slug
      assert_includes out, 'question'
      assert_includes out, 'sc-1'
      assert_match(/^---/, out, 'rule separator should be present')
    end
  end

  def test_renders_em_dash_for_dock_without_inbox_event
    with_dock_config do |config|
      slug = 'sc-2'
      metadata = JSON.pretty_generate('slug' => slug, 'created_at' => Time.now.utc.iso8601)
      make_workspace(config, slug, files: { config.metadata_filename => metadata })
      Dock::Docker.stubs(:list_projects).returns([{ 'Name' => slug }])
      Dock::Inbox.stubs(:last_event).returns(nil)

      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      assert_match(/sc-2.*—/, out)
    end
  end

  def test_renders_corrupt_marker_when_metadata_is_invalid_json
    with_dock_config do |config|
      slug = 'sc-3'
      make_workspace(config, slug, files: { config.metadata_filename => 'not json{' })
      Dock::Docker.stubs(:list_projects).returns([{ 'Name' => slug }])

      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      assert_match(/sc-3.*corrupt/, out)
    end
  end

  def test_age_formats_seconds_minutes_hours_days
    cmd = build_list_with_no_data
    assert_equal '30s', cmd.send(:age, (Time.now - 30).utc.iso8601)
    assert_equal '5m',  cmd.send(:age, (Time.now - 300).utc.iso8601)
    assert_equal '2h',  cmd.send(:age, (Time.now - (2 * 3600)).utc.iso8601)
    assert_equal '3d',  cmd.send(:age, (Time.now - (3 * 86_400)).utc.iso8601)
  end

  def test_skips_compose_projects_with_invalid_slug_names
    # Docker permits names our slug regex rejects (underscores, uppercase).
    # The list must skip them rather than crash via Inbox.path_for.
    with_dock_config do |config|
      Dock::Docker.stubs(:list_projects).returns([
                                                   { 'Name' => 'has_underscore' },
                                                   { 'Name' => 'UPPERCASE' },
                                                   { 'Name' => '../traversal' }
                                                 ])
      out, _err = capture_io { Dock::Commands::List.new(config: config).call }
      assert_match(/No active docks/, out)
    end
  end

  def test_age_returns_em_dash_when_timestamp_is_unparseable
    cmd = build_list_with_no_data
    assert_equal '—', cmd.send(:age, 'not-a-timestamp')
    assert_equal '—', cmd.send(:age, nil)
  end

  private

  def build_list_with_no_data
    config = nil
    with_dock_config { |c| config = c }
    # config is captured *after* mktmpdir cleaned up, but List#age doesn't touch FS.
    Dock::Commands::List.new(config: config)
  end
end
