# frozen_string_literal: true

require_relative '../test_helper'

class Dock::FingerprintTest < Minitest::Test
  def test_compute_is_deterministic_for_same_inputs
    a = Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/p', created_at: '2026-01-01T00:00:00Z')
    b = Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/p', created_at: '2026-01-01T00:00:00Z')
    assert_equal a, b
    assert_equal 64, a.length, 'SHA256 hex is 64 chars'
  end

  def test_compute_differs_when_any_input_changes
    base = Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/p', created_at: 't')
    refute_equal base, Dock::Fingerprint.compute(slug: 'sc-2', parent_dir: '/p', created_at: 't')
    refute_equal base, Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/q', created_at: 't')
    refute_equal base, Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/p', created_at: 'u')
  end

  def test_write_then_read_roundtrip_returns_same_value
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      Dock::Fingerprint.write(workspace_path: ws, value: 'abc123', config: config)
      assert_equal 'abc123', Dock::Fingerprint.read(workspace_path: ws, config: config)
    end
  end

  def test_read_returns_nil_when_file_missing
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      assert_nil Dock::Fingerprint.read(workspace_path: ws, config: config)
    end
  end

  def test_write_creates_parent_dot_dock_directory
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      Dock::Fingerprint.write(workspace_path: ws, value: 'x', config: config)
      assert File.directory?(File.join(ws, '.dock'))
    end
  end

  def test_verify_succeeds_when_stored_matches_recomputed
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      metadata = { 'slug' => 'sc-1', 'parent_dir' => '/p', 'created_at' => 't0' }
      fp = Dock::Fingerprint.compute(slug: 'sc-1', parent_dir: '/p', created_at: 't0')
      Dock::Fingerprint.write(workspace_path: ws, value: fp, config: config)

      assert_nil Dock::Fingerprint.verify!(workspace_path: ws, metadata: metadata, config: config)
    end
  end

  def test_verify_raises_when_stored_mismatches_metadata
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      Dock::Fingerprint.write(workspace_path: ws, value: 'bogus', config: config)
      metadata = { 'slug' => 'sc-1', 'parent_dir' => '/p', 'created_at' => 't0' }

      error = assert_raises(Dock::Error) do
        Dock::Fingerprint.verify!(workspace_path: ws, metadata: metadata, config: config)
      end
      assert_match(/fingerprint mismatch/, error.message)
    end
  end

  def test_verify_raises_when_file_missing
    with_dock_config do |config|
      ws = make_workspace(config, 'sc-1')
      metadata = { 'slug' => 'sc-1', 'parent_dir' => '/p', 'created_at' => 't0' }
      error = assert_raises(Dock::Error) do
        Dock::Fingerprint.verify!(workspace_path: ws, metadata: metadata, config: config)
      end
      assert_match(/fingerprint missing/, error.message)
    end
  end
end
