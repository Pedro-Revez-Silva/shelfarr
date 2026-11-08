# frozen_string_literal: true

require "base64"
require "cgi"

module Kobo
  # Kobo has no public third-party OAuth registration for this integration.
  # This uses the reader activation protocol: approval stays on Kobo's site.
  class AccountClient
    PLATFORM_ID = "00000000-0000-0000-0000-000000000373"
    APP_VERSION = "4.38.23171"
    ACTIVATION_LIFETIME = 10.minutes
    MAX_TOKEN_BYTES = 16.kilobytes
    Activation = Data.define(:poll_url, :code, :expires_at)
    Identity = Data.define(:user_id, :user_key, :email)
    Page = Data.define(:items, :cursor, :more, :bytes)

    def initialize(account, transport: HttpClient.new)
      @account = account
      @transport = transport
    end

    def start_activation
      query = URI.encode_www_form(pwspid: PLATFORM_ID, wsa: "Kobo", pwsdid: @account.device_id,
        pwsav: APP_VERSION, pwsdm: PLATFORM_ID, pwspos: "3.0.35+", pwspov: "NA")
      response = @transport.call(origin: :auth, path: "/ActivateOnWeb?#{query}")
      document = Nokogiri::HTML(response.body)
      poll = document.at_css("[data-poll-endpoint]")&.[]("data-poll-endpoint")
      code = response.body.match(/qrcodegenerator\/generate[^"<>]*?%26code%3D(\d{6,12})(?!\d)/i)&.[](1)
      raise HttpClient::Error, "protocol_changed" unless code && poll

      Activation.new(poll_url: validated_poll_path(poll), code: code, expires_at: ACTIVATION_LIFETIME.from_now)
    end

    def poll_activation
      result = json(@transport.call(origin: :auth, path: validated_poll_path(@account.activation_poll_url), method: :post))
      return nil if result["Status"] == "Pending"
      raise HttpClient::Error, "activation_expired" if %w[Expired Cancelled].include?(result["Status"])
      raise HttpClient::Error, "protocol_changed" unless result["Status"] == "Complete"

      uri = URI.parse(bounded_string(result["RedirectUrl"], 32.kilobytes))
      unless uri.scheme == "kobo" && uri.host.to_s.casecmp?("UserAuthenticated") && uri.userinfo.nil? && uri.path.to_s.empty? && uri.fragment.nil?
        raise HttpClient::Error, "protocol_changed"
      end
      values = CGI.parse(uri.query.to_s)
      id, key, email = %w[userId userKey email].map do |name|
        raise HttpClient::Error, "protocol_changed" unless values[name]&.size == 1

        bounded_string(values[name].first, name == "email" ? 512 : MAX_TOKEN_BYTES)
      end
      Identity.new(user_id: id, user_key: key, email: email)
    rescue URI::InvalidURIError
      raise HttpClient::Error, "protocol_changed"
    end

    def authenticate(identity)
      body = { AffiliateName: "Kobo", AppVersion: APP_VERSION, ClientKey: client_key,
        DeviceId: @account.device_id, PlatformId: PLATFORM_ID, SerialNumber: @account.serial_number, UserKey: identity.user_key }
      tokens = token_set(@transport.call(origin: :store, path: "/v1/auth/device", method: :post, body: body))
      tokens.merge(kobo_user_id: identity.user_id, kobo_user_key: identity.user_key, kobo_email: identity.email)
    end

    def refresh
      body = { AppVersion: APP_VERSION, ClientKey: client_key, PlatformId: PLATFORM_ID, RefreshToken: @account.refresh_token }
      token_set(@transport.call(origin: :store, path: "/v1/auth/refresh", method: :post, body: body, headers: authorization))
    end

    def library_page(cursor: nil)
      headers = authorization
      headers["x-kobo-synctoken"] = bounded_string(cursor, MAX_TOKEN_BYTES) if cursor
      response = @transport.call(origin: :store, path: "/v1/library/sync", headers: headers)
      items = json(response, type: Array)
      raise HttpClient::Error, "protocol_changed" unless items.all? { |item| item.is_a?(Hash) }

      more = response.headers["x-kobo-sync"].to_s.casecmp?("continue")
      next_cursor = more ? bounded_string(response.headers["x-kobo-synctoken"], MAX_TOKEN_BYTES) : nil
      Page.new(items: items, cursor: next_cursor, more: more, bytes: response.body.bytesize)
    end

    private

    def validated_poll_path(value)
      uri = URI.parse(value.to_s)
      if uri.absolute? && !(uri.scheme == "https" && uri.host == "auth.kobobooks.com" && uri.port == 443 && uri.userinfo.nil?)
        raise HttpClient::Error, "protocol_changed"
      end
      query = CGI.parse(uri.query.to_s)
      unless uri.host.nil? || uri.absolute?
        raise HttpClient::Error, "protocol_changed"
      end
      unless uri.fragment.nil? && uri.path.match?(%r{\A/(?:[a-z]{2}(?:-[a-z]{2})?/){0,2}activateonweb/poll\z}i) &&
          query.keys == [ "workflowId" ] && query["workflowId"].size == 1 && query["workflowId"].first.match?(/\A[A-Za-z0-9._~-]{1,512}\z/)
        raise HttpClient::Error, "protocol_changed"
      end
      uri.path + "?" + uri.query
    rescue URI::InvalidURIError
      raise HttpClient::Error, "protocol_changed"
    end

    def client_key
      Base64.strict_encode64(PLATFORM_ID)
    end

    def authorization
      { "Authorization" => "Bearer #{bounded_string(@account.access_token, MAX_TOKEN_BYTES)}" }
    end

    def token_set(response)
      result = json(response)
      raise HttpClient::Error, "protocol_changed" unless result["TokenType"] == "Bearer"

      { access_token: bounded_string(result["AccessToken"], MAX_TOKEN_BYTES), refresh_token: bounded_string(result["RefreshToken"], MAX_TOKEN_BYTES) }
    end

    def json(response, type: Hash)
      value = JSON.parse(FilenameBytes.utf8(response.body))
      raise HttpClient::Error, "protocol_changed" unless value.is_a?(type)

      value
    rescue JSON::ParserError, EncodingError
      raise HttpClient::Error, "protocol_changed"
    end

    def bounded_string(value, maximum)
      unless value.is_a?(String) && value.present? && value.bytesize <= maximum && !value.match?(/[\x00-\x1f\x7f]/)
        raise HttpClient::Error, "protocol_changed"
      end
      value
    end
  end
end
