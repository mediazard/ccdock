# frozen_string_literal: true

require_relative '../test_helper'

class Dock::CaddyTest < Minitest::Test
  ROUTES_URL = 'http://localhost:2019/config/apps/http/servers/srv0/routes'

  def teardown
    WebMock.reset!
  end

  def test_register_wildcard_posts_expected_route_to_caddy
    with_dock_config do |config|
      stub_request(:post, ROUTES_URL).to_return(status: 200, body: '')

      id = Dock::Caddy.register_wildcard(slug: 'sc-1', port: 49_152, config: config)

      assert_equal 'ws-sc-1', id
      assert_requested(:post, ROUTES_URL) do |req|
        assert_equal 'application/json', req.headers['Content-Type']
        payload = JSON.parse(req.body)
        assert_equal 'ws-sc-1', payload['@id']
        assert_equal ['*.sc-1-dev.localhost'], payload.dig('match', 0, 'host')
        assert_equal 'reverse_proxy', payload.dig('handle', 0, 'handler')
        assert_equal 'localhost:49152', payload.dig('handle', 0, 'upstreams', 0, 'dial')
        assert_equal true, payload['terminal']
      end
    end
  end

  def test_register_wildcard_raises_when_caddy_returns_non_2xx
    with_dock_config do |config|
      stub_request(:post, ROUTES_URL).to_return(status: 500, body: 'internal error')

      error = assert_raises(Dock::CaddyError) do
        Dock::Caddy.register_wildcard(slug: 'sc-1', port: 1234, config: config)
      end
      assert_match(/Failed to register route ws-sc-1/, error.message)
      assert_match(/500/, error.message)
    end
  end

  def test_delete_route_happy_path_issues_delete_when_id_matches_prefix
    stub_request(:get, 'http://localhost:2019/id/ws-sc-1')
      .to_return(status: 200, body: { '@id' => 'ws-sc-1' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    stub_request(:delete, 'http://localhost:2019/id/ws-sc-1').to_return(status: 200, body: '')

    Dock::Caddy.delete_route(slug: 'sc-1')
    assert_requested(:delete, 'http://localhost:2019/id/ws-sc-1')
  end

  def test_delete_route_refuses_when_existing_route_id_does_not_match_prefix
    stub_request(:get, 'http://localhost:2019/id/ws-sc-1')
      .to_return(status: 200, body: { '@id' => 'srv0-default' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })

    # No DELETE should be issued at all — if one is, WebMock will raise.
    out, _err = capture_io { Dock::Caddy.delete_route(slug: 'sc-1') }
    _ = out
  end

  def test_delete_route_silently_returns_when_route_not_found
    stub_request(:get, 'http://localhost:2019/id/ws-sc-1').to_return(status: 404, body: '')
    # 404 means no DELETE follows. If a DELETE were issued, WebMock would raise.
    Dock::Caddy.delete_route(slug: 'sc-1')
  end

  def test_delete_route_handles_connection_refused_gracefully
    stub_request(:get, 'http://localhost:2019/id/ws-sc-1').to_raise(Errno::ECONNREFUSED)
    out, err = capture_io { Dock::Caddy.delete_route(slug: 'sc-1') }
    _ = out
    assert_match(/Caddy admin API not reachable/, err)
  end

  def test_delete_route_handles_non_json_response_gracefully
    stub_request(:get, 'http://localhost:2019/id/ws-sc-1').to_return(status: 200, body: 'not json{')
    out, err = capture_io { Dock::Caddy.delete_route(slug: 'sc-1') }
    _ = out
    assert_match(/non-JSON/, err)
  end

  def test_route_id_helper_prepends_ws_prefix
    assert_equal 'ws-sc-1', Dock::Caddy.route_id('sc-1')
  end

  def test_register_wildcard_rejects_invalid_slug
    with_dock_config do |config|
      assert_raises(Dock::Slug::InvalidSlugError) do
        Dock::Caddy.register_wildcard(slug: '../escape', port: 1234, config: config)
      end
    end
  end

  def test_register_wildcard_rejects_invalid_port
    with_dock_config do |config|
      assert_raises(Dock::CaddyError) do
        Dock::Caddy.register_wildcard(slug: 'sc-1', port: 'not-a-port', config: config)
      end
      assert_raises(Dock::CaddyError) do
        Dock::Caddy.register_wildcard(slug: 'sc-1', port: 0, config: config)
      end
      assert_raises(Dock::CaddyError) do
        Dock::Caddy.register_wildcard(slug: 'sc-1', port: 99_999, config: config)
      end
    end
  end

  def test_delete_route_rejects_invalid_slug
    assert_raises(Dock::Slug::InvalidSlugError) do
      Dock::Caddy.delete_route(slug: 'foo/bar')
    end
  end
end
