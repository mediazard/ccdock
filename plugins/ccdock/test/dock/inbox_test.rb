# frozen_string_literal: true

require_relative '../test_helper'

class Dock::InboxTest < Minitest::Test
  def test_path_for_joins_inbox_dir_and_slug_jsonl
    with_dock_config do |config|
      assert_equal File.join(config.inbox_dir, 'sc-1.jsonl'),
                   Dock::Inbox.path_for(slug: 'sc-1', config: config)
    end
  end

  def test_ensure_dir_creates_inbox_directory
    with_inbox_config do |config|
      refute File.directory?(config.inbox_dir)
      Dock::Inbox.ensure_dir(config: config)
      assert File.directory?(config.inbox_dir)
    end
  end

  def test_last_event_returns_parsed_last_jsonl_line
    with_inbox_config do |config|
      write_inbox(config, 'sc-1', [
                    { ts: 't1', event: 'question', message: 'first' },
                    { ts: 't2', event: 'idle',     message: 'second' }
                  ])

      event = Dock::Inbox.last_event(slug: 'sc-1', config: config)
      assert_equal 'idle', event['event']
      assert_equal 't2', event['ts']
    end
  end

  def test_last_event_returns_nil_when_inbox_missing
    with_inbox_config do |config|
      assert_nil Dock::Inbox.last_event(slug: 'missing', config: config)
    end
  end

  def test_last_event_returns_nil_when_file_is_empty
    with_inbox_config do |config|
      path = Dock::Inbox.path_for(slug: 'sc-1', config: config)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')
      assert_nil Dock::Inbox.last_event(slug: 'sc-1', config: config)
    end
  end

  def test_last_event_returns_nil_when_last_line_is_blank
    with_inbox_config do |config|
      path = Dock::Inbox.path_for(slug: 'sc-1', config: config)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{\"event\":\"idle\"}\n\n")
      assert_nil Dock::Inbox.last_event(slug: 'sc-1', config: config),
                 'trailing blank line resets accumulator to nil per implementation'
    end
  end

  def test_last_event_returns_nil_when_last_line_is_corrupt_json
    with_inbox_config do |config|
      path = Dock::Inbox.path_for(slug: 'sc-1', config: config)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{\"event\":\"idle\"}\nnot json{\n")
      assert_nil Dock::Inbox.last_event(slug: 'sc-1', config: config)
    end
  end

  def test_remove_is_idempotent_for_missing_file
    with_inbox_config do |config|
      Dock::Inbox.remove(slug: 'never-existed', config: config) # no raise
    end
  end

  def test_path_for_rejects_path_traversal_slug
    with_dock_config do |config|
      assert_raises(Dock::Slug::InvalidSlugError) do
        Dock::Inbox.path_for(slug: '../escape', config: config)
      end
      assert_raises(Dock::Slug::InvalidSlugError) do
        Dock::Inbox.path_for(slug: 'foo/bar', config: config)
      end
    end
  end

  def test_remove_deletes_existing_inbox_file
    with_inbox_config do |config|
      write_inbox(config, 'sc-1', [{ event: 'idle' }])
      path = Dock::Inbox.path_for(slug: 'sc-1', config: config)
      assert File.exist?(path)

      Dock::Inbox.remove(slug: 'sc-1', config: config)
      refute File.exist?(path)
    end
  end

  private

  # Wrap with_dock_config so inbox_dir points inside the tmp sandbox.
  def with_inbox_config(&block)
    Dir.mktmpdir('ccdock-test-inbox-') do |tmp|
      with_dock_config(inbox_dir: File.join(tmp, 'inbox'), &block)
    end
  end

  def write_inbox(config, slug, events)
    path = Dock::Inbox.path_for(slug: slug, config: config)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, events.map { |e| "#{JSON.dump(e)}\n" }.join)
  end
end
