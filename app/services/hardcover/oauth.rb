# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module Hardcover
  # Hardcover OAuth 2.1 client (authorization code + PKCE S256, device
  # authorization grant, refresh-token rotation, revocation).
  #
  # Shelfarr is self-hosted, so it never ships a client ID or secret. Each
  # instance's administrator registers their own Hardcover app and enters its
  # client ID (and, for a "Web app" registration, its secret).
  module Oauth
    ISSUER = "https://api.hardcover.app"
    API_ORIGIN = ISSUER
    WEB_ORIGIN = "https://hardcover.app"
    DISCOVERY_URL = "#{ISSUER}/.well-known/oauth-authorization-server".freeze
    DEFAULT_ENDPOINTS = {
      "issuer" => ISSUER,
      "authorization_endpoint" => "#{WEB_ORIGIN}/oauth2/authorize",
      "token_endpoint" => "#{API_ORIGIN}/oauth2/token",
      "revocation_endpoint" => "#{API_ORIGIN}/oauth2/revoke",
      "device_authorization_endpoint" => "#{API_ORIGIN}/oauth2/device"
    }.freeze
    ALLOWED_HOSTS = %w[hardcover.app api.hardcover.app].freeze
    # Discovered endpoints may only move to another plain path on one of
    # Hardcover's origins: no empty, dot, or encoded segments, and nothing
    # that another URL parser could read as a different host.
    ENDPOINT_PATH = %r{\A(?:/[A-Za-z0-9_~-]+(?:\.[A-Za-z0-9_~-]+)*)+\z}
    MAX_ENDPOINT_BYTES = 512
    DISCOVERY_CACHE_KEY = "hardcover:oauth:discovery:v1"
    DISCOVERY_TTL = 1.day
    PENDING_TTL = 10.minutes
    DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
    REFRESH_LOCK_TTL = 45.seconds

    class Error < StandardError; end
    # The authorization was refused, expired, or the refresh token is no
    # longer valid. The user must connect again.
    class AuthorizationError < Error; end
    # The connection was replaced or removed while a refresh was in flight.
    class ConnectionChanged < Error; end

    TokenSet = Data.define(:access_token, :refresh_token, :expires_at, :scope)
    DeviceAuthorization = Data.define(:device_code, :user_code, :verification_uri, :verification_uri_complete, :expires_at, :interval)
    DevicePoll = Data.define(:status, :token_set, :interval)

    class << self
      def generate_pkce
        verifier = SecureRandom.urlsafe_base64(48)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        [ verifier, challenge ]
      end

      def authorization_url(state:, code_challenge:, redirect_uri:)
        params = {
          response_type: "code",
          client_id: HardcoverIntegration.oauth_client_id,
          redirect_uri: redirect_uri,
          state: state,
          code_challenge: code_challenge,
          code_challenge_method: "S256",
          scope: HardcoverIntegration::OAUTH_SCOPES.join(" ")
        }
        "#{endpoint('authorization_endpoint')}?#{params.to_query}"
      end

      # RFC 9207: the callback names the issuer that minted the code. Anything
      # else could be a mix-up attack, so the code must not be redeemed.
      def valid_issuer?(value)
        ActiveSupport::SecurityUtils.secure_compare(value.to_s, endpoint("issuer"))
      end

      def exchange_code(code:, code_verifier:, redirect_uri:)
        token_request(
          grant_type: "authorization_code",
          code: code,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri
        )
      end

      def refresh(refresh_token)
        token_request(grant_type: "refresh_token", refresh_token: refresh_token)
      end

      def start_device_authorization
        body = post_form("device_authorization_endpoint", client_fields(scope: HardcoverIntegration::OAUTH_SCOPES.join(" ")))
        unless body["device_code"].present? && body["user_code"].present?
          raise Error, "Hardcover did not start the device sign-in"
        end

        DeviceAuthorization.new(
          device_code: body["device_code"].to_s,
          user_code: body["user_code"].to_s.first(32),
          verification_uri: safe_hardcover_url(body["verification_uri"]) || "https://hardcover.app/link",
          verification_uri_complete: safe_hardcover_url(body["verification_uri_complete"]),
          expires_at: Time.current + Integer(body["expires_in"] || 900, exception: false).to_i.clamp(60, 1800),
          interval: Integer(body["interval"] || 5, exception: false).to_i.clamp(5, 60)
        )
      end

      def poll_device_authorization(device_code)
        token_set = token_request(grant_type: DEVICE_GRANT_TYPE, device_code: device_code)
        DevicePoll.new(status: :approved, token_set: token_set, interval: nil)
      rescue AuthorizationError => e
        case e.message
        when "authorization_pending" then DevicePoll.new(status: :pending, token_set: nil, interval: nil)
        when "slow_down" then DevicePoll.new(status: :slow_down, token_set: nil, interval: 5)
        when "access_denied" then DevicePoll.new(status: :denied, token_set: nil, interval: nil)
        when "expired_token" then DevicePoll.new(status: :expired, token_set: nil, interval: nil)
        else raise
        end
      end

      # Revoking either token revokes the pair. Failures are logged and
      # ignored: the local copy is deleted regardless.
      def revoke(token)
        return false if token.blank?

        post_form("revocation_endpoint", client_fields(token: token, token_type_hint: "refresh_token"), allow_error: true)
        true
      rescue Error, Faraday::Error => e
        Rails.logger.warn("[Hardcover::Oauth] Token revocation failed: #{e.class}")
        false
      end

      # Refresh tokens rotate and Hardcover revokes the whole chain if one is
      # reused, so only one process may refresh a connection at a time and the
      # newest token must be stored before anything else uses it.
      #
      # The network call happens outside any transaction. Its result is only
      # saved if the row still holds the version that was refreshed; if the
      # account was replaced or disconnected meanwhile, the rotated tokens
      # belong to nobody and are revoked instead of being stored.
      def refresh_connection!(connection, force: false)
        raise AuthorizationError, "This Hardcover connection cannot be refreshed" unless connection.refreshable?

        token_in_use = connection.access_token
        account_in_use = connection.hardcover_user_id
        with_refresh_lock(connection) do
          current = HardcoverConnection.find_by(id: connection.id)
          raise ConnectionChanged, "The Hardcover connection was removed" unless current
          raise ConnectionChanged, "A different Hardcover account was connected" if current.hardcover_user_id != account_in_use

          # Another process already rotated the tokens while we waited.
          if current.access_token != token_in_use || !current.refreshable?
            connection.reload
            return connection
          end
          unless force || current.access_token_expiring?
            connection.reload
            return connection
          end

          token_set = refresh(current.refresh_token)
          begin
            current.update!(
              access_token: token_set.access_token,
              refresh_token: token_set.refresh_token.presence || current.refresh_token,
              access_token_expires_at: token_set.expires_at,
              granted_scopes: token_set.scope.presence || current.granted_scopes,
              refreshed_at: Time.current,
              status: "active",
              last_error: nil
            )
          rescue ActiveRecord::StaleObjectError
            revoke(token_set.refresh_token.presence || token_set.access_token)
            raise ConnectionChanged, "The Hardcover connection changed while it was being refreshed"
          end
          connection.reload
        end
      end

      # Every read rebuilds the URL from a server-owned origin, so neither the
      # discovery document nor a cached copy of it can choose the scheme,
      # host, port, credentials, query, or fragment a request goes to.
      def endpoint(name)
        default = DEFAULT_ENDPOINTS.fetch(name)
        return default if name == "issuer"

        hardcover_endpoint(discovery[name]) || default
      end

      def reset_discovery!
        Rails.cache.delete(DISCOVERY_CACHE_KEY)
      rescue StandardError
        nil
      end

      private

      def discovery
        cached = Rails.cache.read(DISCOVERY_CACHE_KEY)
        return cached if cached.is_a?(Hash)

        document = fetch_discovery
        Rails.cache.write(DISCOVERY_CACHE_KEY, document, expires_in: DISCOVERY_TTL)
        document
      rescue StandardError => e
        Rails.logger.warn("[Hardcover::Oauth] Discovery failed, using documented endpoints: #{e.class}")
        DEFAULT_ENDPOINTS
      end

      # Discovery may update endpoint locations but must not redirect tokens
      # or codes to a host outside Hardcover.
      def fetch_discovery
        response = http.get(DISCOVERY_URL)
        raise Error, "discovery status #{response.status}" unless response.status == 200

        body = parse_json(response.body)
        raise Error, "discovery issuer mismatch" unless body["issuer"] == ISSUER

        DEFAULT_ENDPOINTS.keys.excluding("issuer").index_with do |key|
          hardcover_endpoint(body[key]) || DEFAULT_ENDPOINTS[key]
        end
      end

      # Returns the endpoint rebuilt from one of Hardcover's own origins and a
      # checked path, or nil for anything else.
      def hardcover_endpoint(value)
        value = value.to_s
        return if value.bytesize > MAX_ENDPOINT_BYTES || value.match?(/[^\x21-\x7e]|\\/)

        uri = URI.parse(value)
        return unless uri.is_a?(URI::HTTPS) && uri.port == URI::HTTPS::DEFAULT_PORT
        return unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        origin = case uri.host.to_s.downcase
        when "api.hardcover.app" then API_ORIGIN
        when "hardcover.app" then WEB_ORIGIN
        end
        path = uri.path.to_s
        "#{origin}#{path}" if origin && path.match?(ENDPOINT_PATH)
      rescue URI::InvalidURIError
        nil
      end

      def token_request(**fields)
        body = post_form("token_endpoint", client_fields(**fields))
        access_token = body["access_token"].to_s
        raise Error, "Hardcover did not return an access token" if access_token.blank?

        expires_in = Integer(body["expires_in"], exception: false)
        TokenSet.new(
          access_token: access_token,
          refresh_token: body["refresh_token"].to_s.presence,
          expires_at: expires_in&.positive? ? Time.current + expires_in : nil,
          scope: body["scope"].to_s.presence
        )
      end

      # Confidential ("Web app") clients authenticate with HTTP Basic; public
      # clients identify themselves with client_id and rely on PKCE.
      def client_fields(**fields)
        fields = fields.compact
        fields[:client_id] = HardcoverIntegration.oauth_client_id unless HardcoverIntegration.confidential_client?
        fields
      end

      # Takes the endpoint's name rather than a URL so callers cannot send the
      # client credentials and tokens anywhere but Hardcover. Redirects are
      # not followed: a 3xx is an error like any other non-2xx answer.
      def post_form(endpoint_name, fields, allow_error: false)
        raise Error, "Hardcover OAuth is not configured" if HardcoverIntegration.oauth_client_id.blank?

        url = endpoint(endpoint_name)
        response = http.post(url) do |request|
          request.headers["Content-Type"] = "application/x-www-form-urlencoded"
          request.headers["Accept"] = "application/json"
          if HardcoverIntegration.confidential_client?
            credentials = "#{CGI.escape(HardcoverIntegration.oauth_client_id)}:#{CGI.escape(HardcoverIntegration.oauth_client_secret)}"
            request.headers["Authorization"] = "Basic #{Base64.strict_encode64(credentials)}"
          end
          request.body = URI.encode_www_form(fields)
        end
        body = parse_json(response.body)
        return body if response.status.between?(200, 299) || allow_error

        error = body["error"].to_s.presence || "http_#{response.status}"
        Rails.logger.warn("[Hardcover::Oauth] Request failed: #{error}")
        if response.status.in?([ 400, 401, 403 ])
          raise AuthorizationError, error
        else
          raise Error, "Hardcover sign-in is temporarily unavailable (#{error})"
        end
      rescue Faraday::Error => e
        raise Error, "Could not reach Hardcover: #{e.class.name.demodulize}"
      end

      def http
        Faraday.new do |f|
          f.adapter Faraday.default_adapter
          f.headers["User-Agent"] = "Shelfarr/1.0"
          f.options.timeout = 15
          f.options.open_timeout = 5
        end
      end

      def parse_json(body)
        return body if body.is_a?(Hash)

        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # Links shown to the person signing in (they may carry the user code in
      # the query). Shelfarr never requests them itself.
      def safe_hardcover_url(value)
        uri = URI.parse(value.to_s)
        return unless uri.is_a?(URI::HTTPS) && uri.port == URI::HTTPS::DEFAULT_PORT && uri.userinfo.nil?

        value.to_s if ALLOWED_HOSTS.include?(uri.host.to_s.downcase)
      rescue URI::InvalidURIError
        nil
      end

      def with_refresh_lock(connection)
        key = "hardcover:oauth:refresh-lock:#{connection.id}"
        token = SecureRandom.hex(16)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REFRESH_LOCK_TTL
        until Rails.cache.write(key, token, expires_in: REFRESH_LOCK_TTL, unless_exist: true)
          raise Error, "Another Shelfarr process is refreshing this Hardcover connection" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.2
        end
        begin
          yield
        ensure
          Rails.cache.delete(key) if Rails.cache.read(key) == token
        end
      end
    end
  end
end
