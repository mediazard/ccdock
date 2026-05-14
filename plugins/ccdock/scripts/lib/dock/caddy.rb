# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Dock
  # Caddy admin API client.
  #
  # Registers a wildcard reverse-proxy route per workspace at *.<slug>-<base_host>
  # pointing to localhost:<dynamic_web_port>. Uses POST /id/... only (atomic single-route
  # ops); never POST /load (whole-config replace) which would race under concurrent setups.
  module Caddy
    ADMIN_URL = 'http://localhost:2019'
    ROUTE_ID_PREFIX = 'ws-'

    module_function

    # @param slug [String]
    # @param port [Integer, String] host port the workspace's web container is bound to
    # @param config [Dock::Config]
    def register_wildcard(slug:, port:, config:)
      Slug.validate!(slug)
      validate_port!(port)
      route = {
        '@id' => route_id(slug),
        'match' => [{ 'host' => ["*.#{slug}-#{config.base_host}"] }],
        'handle' => [
          {
            'handler' => 'reverse_proxy',
            # Caddy runs on the host (not inside Docker), so we proxy to localhost.
            # The workspace's web container publishes its dynamic port to host loopback.
            'upstreams' => [{ 'dial' => "localhost:#{port}" }]
          }
        ],
        'terminal' => true
      }

      uri = URI("#{ADMIN_URL}/config/apps/http/servers/srv0/routes")
      response = post(uri, route.to_json)
      raise CaddyError, "Failed to register route #{route_id(slug)}: #{response.code} #{response.body}" \
        unless response.is_a?(Net::HTTPSuccess)

      route_id(slug)
    end

    # @param slug [String]
    def delete_route(slug:)
      Slug.validate!(slug)
      id = route_id(slug)
      uri = URI("#{ADMIN_URL}/id/#{id}")

      get_response = Net::HTTP.get_response(uri)
      return unless get_response.is_a?(Net::HTTPSuccess)

      # Defense in depth: verify the route's @id matches our prefix before delete.
      payload = JSON.parse(get_response.body)
      actual_id = payload['@id']
      unless actual_id.is_a?(String) && actual_id.start_with?(ROUTE_ID_PREFIX)
        warn "Caddy route #{id} exists but @id (#{actual_id.inspect}) lacks expected prefix — refusing delete."
        return
      end

      delete = Net::HTTP::Delete.new(uri.path)
      response = Net::HTTP.new(uri.host, uri.port).request(delete)
      return if response.is_a?(Net::HTTPSuccess)

      warn "Failed to delete Caddy route #{id}: #{response.code} #{response.body}"
    rescue Errno::ECONNREFUSED
      warn 'Caddy admin API not reachable — skipping route deletion.'
    rescue JSON::ParserError
      warn "Caddy returned non-JSON for #{id} — skipping delete."
    end

    def route_id(slug)
      "#{ROUTE_ID_PREFIX}#{slug}"
    end

    def post(uri, body)
      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
        request.body = body
        http.request(request)
      end
    end
    private_class_method :post

    def validate_port!(port)
      n = Integer(port)
      raise CaddyError, "Invalid port #{port.inspect}" unless n.between?(1, 65_535)
    rescue ArgumentError, TypeError
      raise CaddyError, "Invalid port #{port.inspect}"
    end
    private_class_method :validate_port!
  end
end
