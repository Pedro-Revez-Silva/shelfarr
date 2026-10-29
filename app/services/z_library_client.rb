# frozen_string_literal: true

require "digest"
require "cgi"
require "ipaddr"
require "nokogiri"
require "public_suffix"
require "uri"

class ZLibraryClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end
  class RateLimitError < Error; end
  class ConfigurationError < Error; end
  class SearchCancelled < StandardError; end

  Result = Data.define(
    :id, :hash, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      id.present? && hash.present?
    end
  end

  AUTH_TTL_SECONDS = 30.minutes
  ALLOWED_DOWNLOAD_SCHEMES = %w[http https].freeze
  MAX_LOGIN_ERROR_LENGTH = 200
  MAX_LOGIN_REDIRECTS = 5
  LOGIN_REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
  # 307/308 keep the POST body. 301/302/303 are followed as GET so the
  # password is not replayed to the next URL.
  LOGIN_METHOD_PRESERVING_STATUSES = [ 307, 308 ].freeze
  COOKIE_NAME_PATTERN = "[!#$%&'*+\\-.0-9A-Z^_`a-z|~]+"
  DOMAIN_HEALTH_TTL_SECONDS = 5.minutes
  # DiamWall answers some VPN and datacenter addresses with 517, not a 3xx.
  BOT_WALL_HTTP_STATUS = 517
  # Mirrors that are not in the preferred default list, but are still Z-Library
  # hosts a login redirect may land on.
  ADDITIONAL_KNOWN_ZLIBRARY_HOSTS = %w[
    z-library.sk z-library.bz z-library.rs 1lib.sk z-lib.fm z-lib.sk
  ].freeze
  BOT_WALL_BODY_PATTERN = /
    diamwall |
    verify(?:ing)?\ your\ browser |
    checking\ your\ browser |
    just\ a\ moment |
    cf-browser-verification |
    attention\ required
  /ix

  class << self
    def configured?
      SettingsService.zlibrary_configured?
    end

    def test_connection
      RemoteResult::Ok.new(test_connection!)
    rescue Error => e
      Rails.logger.error "[ZLibraryClient] Connection test failed: #{e.message}"
      RemoteResult::Failed.new(e)
    end

    def test_connection!
      ensure_configured!
      auth = login
      validate_saved_session!(auth) if saved_remix_auth
      # Login can succeed while /eapi/book/search is still bot-walled.
      fetch_search_results(
        auth,
        query: "test",
        file_types: %w[epub pdf],
        limit: 1,
        language: nil,
        after_attempt: nil
      )
      true
    end

    def search(query, file_types: %w[epub pdf], limit: 50, language: nil, after_attempt: nil)
      ensure_configured!

      with_authenticated_retry(context: "search", after_attempt: after_attempt) do |auth|
        Rails.logger.info "[ZLibraryClient] Searching for '#{query}'"
        fetch_search_results(
          auth,
          query: query,
          file_types: file_types,
          limit: limit,
          language: language,
          after_attempt: after_attempt
        )
      end
    end

    def get_download_url(id:, hash:)
      ensure_configured!

      with_authenticated_retry(context: "download lookup") do |auth|
        response = get_file_response(auth, id: id, hash: hash)

        if download_html_fallback_response?(response)
          alternate_download_url = get_download_url_from_alternate_domains(auth, id: id, hash: hash)
          return alternate_download_url if alternate_download_url

          Rails.logger.warn "[ZLibraryClient] eAPI download lookup unavailable; falling back to HTML book page"
          return get_html_download_url(auth, id: id, hash: hash)
        end

        data = parse_response(response, context: "download lookup")
        download_link = data.dig("file", "downloadLink")
        raise Error, "Z-Library did not return a download link" if download_link.blank?

        validate_download_url!(download_link)
        download_link
      end
    end

    def reset_connection!
      @auth_cache = nil
      @domain_health_cache = nil
      @connection = nil
    end

    private

    def validate_saved_session!(auth)
      response = connection.get("#{auth[:base_url]}/eapi/user/profile") do |req|
        req.headers["Cookie"] = cookie_header(auth)
      end

      if [ 401, 403 ].include?(response.status)
        raise AuthenticationError, "Invalid Z-Library saved session"
      end
      unless response.status == 200
        raise ConnectionError, "Z-Library session validation failed with status #{response.status}"
      end

      data = parse_json_body(response)
      unless data.is_a?(Hash) && data["success"] == 1 &&
          data["user"].is_a?(Hash) && data.dig("user", "id").to_s == auth[:remix_userid]
        raise AuthenticationError, "Invalid Z-Library saved session"
      end
    rescue JSON::ParserError, Faraday::ParsingError
      raise ConnectionError, "Z-Library session validation returned an invalid response"
    rescue Faraday::Error
      raise ConnectionError, "Failed to connect to Z-Library for session validation"
    end

    def login(after_attempt: nil)
      cached = @auth_cache
      signature = credential_signature

      if cached.present? &&
          cached[:signature] == signature &&
          cached[:expires_at] > Time.current
        @last_auth_from_cache = true
        return cached[:auth]
      end

      @last_auth_from_cache = false
      auth = perform_login(signature, after_attempt: after_attempt)

      login_failed = auth.nil? || (auth.is_a?(Hash) && auth.key?(:errors))
      if login_failed
        if auth.is_a?(Hash) && auth[:bot_walled]
          raise AuthenticationError, auth[:errors].first.to_s
        end

        error_details = auth.is_a?(Hash) && auth[:errors].present? ? " (#{auth[:errors].join('; ')})" : ""
        raise AuthenticationError, "Z-Library login failed#{error_details}"
      end

      auth
    end

    def perform_login(signature, after_attempt: nil)
      errors = []
      bot_walled = []

      ordered_login_uris.each do |uri|
        domain = uri.host
        health = domain_health(uri, after_attempt: after_attempt)

        if health == :bot_wall
          bot_walled << domain
          next
        elsif !health.is_a?(URI::HTTP)
          errors << "#{domain}: #{health}"
          next
        end

        auth = auth_for_domain(health, after_attempt: after_attempt)

        if auth.nil?
          next
        elsif auth.is_a?(Hash) && auth[:bot_wall]
          forget_healthy_domain(uri)
          bot_walled << domain
          next
        elsif auth.is_a?(Hash) && auth[:error].present?
          errors << "#{domain}: #{auth[:error]}"
          next
        end

        Rails.logger.info "[ZLibraryClient] Login succeeded via #{domain}"
        cache_auth(signature, auth)
        remember_healthy_domain(uri, health)
        return auth
      rescue JSON::ParserError, Faraday::Error => e
        Rails.logger.debug "[ZLibraryClient] Login failed on #{domain}: #{e.message}"
        errors << "#{domain}: #{e.class.name.split('::').last}"
      end

      login_failure(errors, bot_walled)
    end

    def authenticate_uri(uri, after_attempt: nil)
      email = SettingsService.get(:zlibrary_email).to_s.strip
      password = SettingsService.get(:zlibrary_password).to_s
      login_url = "#{uri.to_s.delete_suffix("/")}/eapi/user/login"
      body = URI.encode_www_form(email: email, password: password)

      exchange = follow_exchange(login_url, method: :post, body: body, after_attempt: after_attempt)
      if exchange[:bot_wall]
        Rails.logger.debug "[ZLibraryClient] Login blocked by a bot wall on #{uri.host}"
        return { error: "bot wall", bot_wall: true }
      end
      if exchange[:error]
        Rails.logger.debug "[ZLibraryClient] Login failed on #{uri.host}: #{exchange[:error]}"
        return { error: exchange[:error] }
      end

      response = exchange[:response]
      final_uri = URI.parse(exchange[:url])

      if bot_wall_response?(response)
        Rails.logger.debug "[ZLibraryClient] Login blocked by a bot wall on #{uri.host}"
        return { error: "bot wall", bot_wall: true }
      end

      unless response.status == 200
        Rails.logger.debug "[ZLibraryClient] Login failed on #{uri.host}: HTTP #{response.status}"
        return { error: "HTTP #{response.status}" }
      end

      data = parse_json_body(response)
      unless data.is_a?(Hash)
        Rails.logger.debug "[ZLibraryClient] Login failed on #{uri.host}: invalid response"
        return { error: "invalid response" }
      end

      unless data["success"] == 1
        error_message = normalized_login_error(data["error"]) || "login rejected"
        Rails.logger.debug "[ZLibraryClient] Login failed on #{uri.host}: #{error_message}"
        return { error: error_message }
      end

      user = data["user"].is_a?(Hash) ? data["user"] : {}
      auth = {
        remix_userid: user["id"]&.to_s,
        remix_userkey: user["remix_userkey"]&.to_s,
        domain: final_uri.host,
        base_url: login_base_url(final_uri, uri)
      }

      unless auth[:remix_userid].present? && auth[:remix_userkey].present?
        missing = []
        missing << "user id" unless auth[:remix_userid].present?
        missing << "remix_userkey" unless auth[:remix_userkey].present?
        error_message = "incomplete response (missing #{missing.join(' and ')})"
        Rails.logger.debug "[ZLibraryClient] Login failed on #{uri.host}: #{error_message}"
        return { error: error_message }
      end

      auth
    end

    def follow_exchange(url, method:, body: nil, accept: nil, after_attempt: nil, seed_cookies: nil)
      cookies = {}
      visited = {}
      redirects_followed = 0

      loop do
        # Replay a same-URL redirect when it sets a cookie. An unchanged jar is a loop.
        visit_key = [ method, normalize_login_url(url), login_cookie_header(cookies, url).to_s ]
        return { error: "redirect loop", url: url } if visited[visit_key]

        visited[visit_key] = true
        if bot_wall_url?(url)
          return { bot_wall: true, error: "bot wall", url: url }
        end

        response = observe_search_attempt(after_attempt) do
          send_login_request(
            method,
            url,
            body: body,
            cookies: cookies,
            accept: accept,
            seed_cookies: seed_cookies
          )
        end

        if bot_wall_response?(response)
          return { bot_wall: true, error: "bot wall", response: response, url: url }
        end
        return { response: response, url: url } unless login_redirect?(response)
        return { error: "too many redirects", response: response, url: url } if redirects_followed >= MAX_LOGIN_REDIRECTS

        location = redirect_location(response)
        return { error: "HTTP #{response.status}", response: response, url: url } if location.blank?
        if location.match?(/diamwall/i)
          return { bot_wall: true, error: "bot wall", response: response, url: url }
        end

        target = safe_login_redirect_target(url, location)
        return { error: "HTTP #{response.status} untrusted redirect", response: response, url: url } if target.nil?

        store_login_cookies!(cookies, response, url)
        unless method == :get || LOGIN_METHOD_PRESERVING_STATUSES.include?(response.status)
          method = :get
          body = nil
        end

        url = target
        redirects_followed += 1
      end
    end

    def send_login_request(method, url, body:, cookies:, accept: nil, seed_cookies: nil)
      header = combined_cookie_header(cookies, url, seed_cookies)
      connection.public_send(method, url) do |req|
        req.headers["Accept"] = accept if accept.present?
        req.headers["Cookie"] = header if header.present?
        req.body = body if body.present? && method != :get
      end
    end

    def combined_cookie_header(cookies, url, seed_cookies)
      parts = []
      jar = login_cookie_header(cookies, url)
      parts << jar if jar.is_a?(String) && jar.present?
      seeded = seed_cookie_header(url, seed_cookies)
      parts << seeded if seeded.present?
      parts.join("; ").presence
    end

    # Remix cookies stay off DiamWall and off any host that is not a Z-Library mirror.
    def seed_cookie_header(url, seed_cookies)
      return if seed_cookies.blank?
      return if bot_wall_url?(url)

      allowed = saved_session_cookie_target?(url)
      return unless allowed == true

      seed_cookies
    end

    def saved_session_cookie_target?(url)
      uri = URI.parse(url)
      ALLOWED_DOWNLOAD_SCHEMES.include?(uri.scheme) && allowed_login_redirect_host?(uri.host)
    rescue URI::InvalidURIError => error
      RemoteResult::Failed.new(error)
    end

    def bot_wall_url?(url)
      url.to_s.match?(/diamwall/i)
    end

    def login_redirect?(response)
      LOGIN_REDIRECT_STATUSES.include?(response.status)
    end

    def redirect_location(response)
      location = response.headers["location"]
      location = location.first if location.is_a?(Array)
      location.to_s.strip
    end

    def safe_login_redirect_target(current_url, location)
      return if location.match?(/[[:cntrl:]]/)

      current = URI.parse(current_url)
      target = URI.join(current, location)
      return unless target.is_a?(URI::HTTP)
      return if target.userinfo.present?
      return unless ALLOWED_DOWNLOAD_SCHEMES.include?(target.scheme)
      return if current.scheme == "https" && target.scheme != "https"
      return unless allowed_login_redirect_host?(target.host)

      target.fragment = nil
      target.to_s
    rescue URI::InvalidURIError, URI::InvalidComponentError => error
      RemoteResult::Failed.new(error)
    end

    def allowed_login_redirect_host?(host)
      candidate = normalized_host(host)
      return false if candidate.blank? || !safe_login_hostname?(candidate)
      return true if configured_login_hosts.include?(candidate) || known_zlibrary_hosts.include?(candidate)

      candidate_domain = registrable_domain(candidate)
      return false if candidate_domain.blank?

      (configured_login_hosts + known_zlibrary_hosts).any? do |allowed|
        registrable_domain(allowed) == candidate_domain
      end
    end

    def configured_login_hosts
      configured_uris.map { |configured| normalized_host(configured.host) }
    end

    def known_zlibrary_hosts
      (SettingsService::PREFERRED_EAPI_HOSTS + ADDITIONAL_KNOWN_ZLIBRARY_HOSTS).map { |host| normalized_host(host) }.uniq
    end

    def safe_login_hostname?(host)
      return true if ip_address_host?(host) == true

      host.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/)
    end

    def normalize_login_url(url)
      uri = URI.parse(url)
      host = normalized_host(uri.host)
      port = uri.port
      port_suffix = port && uri.default_port && port != uri.default_port ? ":#{port}" : ""
      path = uri.path.presence || "/"
      query = uri.query ? "?#{uri.query}" : ""
      "#{uri.scheme.to_s.downcase}://#{host}#{port_suffix}#{path}#{query}"
    rescue URI::InvalidURIError
      url.to_s
    end

    def login_base_url(final_uri, configured_uri)
      same_origin = final_uri.scheme == configured_uri.scheme &&
        final_uri.host.casecmp?(configured_uri.host) &&
        final_uri.port == configured_uri.port
      return configured_uri.to_s.delete_suffix("/") if same_origin

      port = final_uri.port
      port_suffix = port && port != final_uri.default_port ? ":#{port}" : ""
      "#{final_uri.scheme}://#{final_uri.host}#{port_suffix}"
    end

    def normalized_host(host)
      host.to_s.strip.downcase.delete_suffix(".").presence
    end

    def registrable_domain(host)
      normalized = normalized_host(host)
      return if normalized.blank? || ip_address_host?(normalized) == true

      PublicSuffix.domain(normalized, default_rule: nil)
    end

    def ip_address_host?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError, ArgumentError => error
      RemoteResult::Failed.new(error)
    end

    def store_login_cookies!(cookies, response, request_url)
      request_uri = URI.parse(request_url)
      each_set_cookie(response) do |raw|
        cookie = parse_login_cookie(raw, request_uri)
        next unless cookie

        key = [ cookie[:name], cookie[:domain], cookie[:path] ]
        if cookie[:delete]
          cookies.delete(key)
        else
          cookies[key] = cookie
        end
      end
    end

    def each_set_cookie(response)
      header = response.headers["set-cookie"]
      values = case header
      when Array
        header.flat_map { |value| split_combined_set_cookie(value.to_s) }
      when String
        split_combined_set_cookie(header)
      else
        []
      end

      values.each { |value| yield value if value.present? }
    end

    def split_combined_set_cookie(header)
      header.split(/,(?=\s*#{COOKIE_NAME_PATTERN}=)/)
    end

    def parse_login_cookie(raw, request_uri)
      segments = raw.to_s.split(";").map(&:strip).reject(&:empty?)
      name, value = segments.shift.to_s.split("=", 2)
      return if name.blank? || value.nil?
      return unless name.match?(/\A#{COOKIE_NAME_PATTERN}\z/o)

      attributes = cookie_attributes(segments)
      host_only = !attributes.key?("domain")
      domain = if host_only
        normalized_host(request_uri.host)
      else
        cookie_domain = normalized_host(attributes["domain"].to_s.delete_prefix("."))
        return unless acceptable_cookie_domain?(cookie_domain, request_uri.host)

        cookie_domain
      end
      return if domain.blank?

      {
        name: name,
        value: value,
        domain: domain,
        host_only: host_only,
        path: cookie_default_path(attributes["path"], request_uri),
        secure: attributes.key?("secure"),
        delete: attributes["max-age"].to_s.strip == "0"
      }
    end

    def cookie_attributes(segments)
      segments.each_with_object({}) do |segment, attributes|
        attribute, attribute_value = segment.split("=", 2)
        attributes[attribute.to_s.downcase] = attribute_value.to_s
      end
    end

    def acceptable_cookie_domain?(cookie_domain, request_host)
      cookie_domain.present? &&
        registrable_domain(cookie_domain).present? &&
        domain_matches_host?(cookie_domain, request_host)
    end

    def domain_matches_host?(domain, host)
      host = normalized_host(host)
      domain = normalized_host(domain)
      return false if host.blank? || domain.blank?

      host == domain || host.end_with?(".#{domain}")
    end

    def cookie_default_path(attribute, request_uri)
      return attribute if attribute.to_s.start_with?("/")

      path = request_uri.path.to_s
      return "/" if path.empty? || !path.start_with?("/")

      slash = path.rindex("/")
      return "/" if slash.nil? || slash.zero?

      path[0...slash]
    end

    def login_cookie_header(cookies, url)
      uri = URI.parse(url)
      pairs = cookies.each_value.filter_map do |cookie|
        next unless login_cookie_matches?(cookie, uri)

        "#{cookie[:name]}=#{cookie[:value]}"
      end
      pairs.join("; ").presence
    rescue URI::InvalidURIError => error
      RemoteResult::Failed.new(error)
    end

    def login_cookie_matches?(cookie, uri)
      return false if cookie[:secure] && uri.scheme != "https"
      return false if cookie[:host_only] && normalized_host(uri.host) != cookie[:domain]
      return false unless domain_matches_host?(cookie[:domain], uri.host)

      cookie_path_matches?(cookie[:path], uri.path)
    end

    def cookie_path_matches?(cookie_path, request_path)
      request_path = request_path.presence || "/"
      cookie_path = cookie_path.presence || "/"
      return true if request_path == cookie_path
      return false unless request_path.start_with?(cookie_path)

      cookie_path.end_with?("/") || request_path[cookie_path.length] == "/"
    end

    def auth_for_domain(uri, after_attempt:)
      if (saved = saved_remix_auth)
        return saved.merge(domain: uri.host, base_url: uri.to_s.delete_suffix("/"))
      end

      authenticate_uri(uri, after_attempt: after_attempt)
    end

    def saved_remix_auth
      return if password_credentials_present?

      userid = SettingsService.get(:zlibrary_remix_userid).to_s.strip
      userkey = SettingsService.get(:zlibrary_remix_userkey).to_s
      return if userid.blank? || userkey.blank?

      { remix_userid: userid, remix_userkey: userkey }
    end

    def password_credentials_present?
      SettingsService.get(:zlibrary_email).to_s.strip.present? &&
        SettingsService.get(:zlibrary_password).to_s.present?
    end

    def ordered_login_uris
      cached = remembered_uri
      uris = configured_uris
      return uris unless cached

      [ cached ] + uris.reject { |uri| same_site_uri?(uri, cached) }
    end

    def domain_health(uri, after_attempt:)
      return @domain_health_cache[:healthy_uri] if remembered_uri && same_site_uri?(uri, remembered_uri)

      probe_domain(uri, after_attempt: after_attempt)
    end

    def probe_domain(uri, after_attempt: nil)
      probed = probe_domains_endpoint(uri, after_attempt: after_attempt)
      return probed if probed.is_a?(URI::HTTP)

      # /eapi/info/domains is anonymous, so a VPN address can bot-wall it while the saved session still works.
      saved = saved_remix_auth
      return probed unless saved && confirm_saved_session_probe?(probed)

      probe_saved_session_domain(uri, saved, after_attempt: after_attempt)
    end

    def probe_domains_endpoint(uri, after_attempt:)
      url = "#{uri.to_s.delete_suffix("/")}/eapi/info/domains"
      exchange = follow_exchange(url, method: :get, accept: "application/json", after_attempt: after_attempt)
      interpret_domains_probe(exchange, uri)
    rescue Faraday::Error, JSON::ParserError => e
      e.class.name.split("::").last
    end

    def interpret_domains_probe(exchange, uri)
      return :bot_wall if exchange[:bot_wall]

      response = exchange[:response]
      return exchange[:error] || "unhealthy" if response.nil?
      return normalized_uri(login_base_url(URI.parse(exchange[:url]), uri)) if domains_json_body?(response)
      return :bot_wall if bot_wall_response?(response)

      response.status == 200 ? "invalid response" : "HTTP #{response.status}"
    end

    def confirm_saved_session_probe?(probed)
      probed == :bot_wall || probed == "HTTP #{BOT_WALL_HTTP_STATUS}"
    end

    def probe_saved_session_domain(uri, auth, after_attempt:)
      url = "#{uri.to_s.delete_suffix("/")}/eapi/user/profile"
      exchange = follow_exchange(
        url,
        method: :get,
        accept: "application/json",
        after_attempt: after_attempt,
        seed_cookies: cookie_header(auth)
      )
      interpret_saved_session_probe(exchange, uri, auth)
    rescue Faraday::Error, JSON::ParserError => e
      e.class.name.split("::").last
    end

    def interpret_saved_session_probe(exchange, uri, auth)
      return :bot_wall if exchange[:bot_wall]

      response = exchange[:response]
      return exchange[:error] || "unhealthy" if response.nil?
      return :bot_wall if saved_session_probe_walled?(response)

      # Parse failures return RemoteResult::Failed, which is truthy, so only an exact true is a healthy profile.
      if saved_session_profile?(response, auth) == true
        return normalized_uri(login_base_url(URI.parse(exchange[:url]), uri))
      end

      response.status == 200 ? "invalid session" : "HTTP #{response.status}"
    end

    def saved_session_probe_walled?(response)
      response.status == BOT_WALL_HTTP_STATUS || bot_wall_response?(response)
    end

    def saved_session_profile?(response, auth)
      return false unless response.status == 200

      data = parse_json_body(response)
      data.is_a?(Hash) && data["success"] == 1 &&
        data["user"].is_a?(Hash) && data.dig("user", "id").to_s == auth[:remix_userid]
    rescue JSON::ParserError => error
      RemoteResult::Failed.new(error)
    end

    def domains_json_body?(response)
      return false unless response.status == 200

      body = response_body_string(response)
      return false if body.lstrip.start_with?("<")

      parse_json_body(response).is_a?(Hash)
    rescue JSON::ParserError => error
      RemoteResult::Failed.new(error)
    end

    def bot_wall_response?(response)
      return true if redirect_location(response).match?(/diamwall/i)
      # A book title can contain a challenge phrase. JSON is not the wall page.
      return false if response.headers["content-type"].to_s.match?(/\bjson\b/i)

      response_body_string(response).match?(BOT_WALL_BODY_PATTERN)
    end

    def response_body_string(response)
      body = response.body
      body.is_a?(String) ? body : body.to_json
    end

    def login_failure(errors, bot_walled)
      bot_walled = bot_walled.uniq
      if bot_walled.any? && errors.empty?
        message = "Z-Library domains are bot-walled (#{bot_walled.join(', ')}). Configure another domain that serves the eAPI."
        Rails.logger.error "[ZLibraryClient] #{message}"
        return { errors: [ message ], bot_walled: true }
      end

      bot_walled.each { |domain| errors << "#{domain}: bot wall" }
      unless errors.empty?
        Rails.logger.error "[ZLibraryClient] Login failed on all configured domains: #{errors.join('; ')}"
      end

      { errors: errors }
    end

    def remembered_uri
      cached = @domain_health_cache
      return unless cached
      return unless cached[:signature] == domain_list_signature
      return unless cached[:expires_at] > Time.current

      configured_uris.find { |uri| same_site_uri?(uri, cached[:uri]) }
    end

    def remember_healthy_domain(uri, healthy_uri)
      @domain_health_cache = {
        signature: domain_list_signature,
        uri: uri,
        healthy_uri: healthy_uri,
        expires_at: Time.current + DOMAIN_HEALTH_TTL_SECONDS
      }
    end

    def forget_healthy_domain(uri)
      cached = remembered_uri
      @domain_health_cache = nil if cached && same_site_uri?(cached, uri)
    end

    def domain_list_signature
      configured_uris.map { |uri| "#{uri.scheme}://#{normalized_host(uri.host)}:#{uri.port}" }.join("\n")
    end

    def same_site_uri?(left, right)
      left.scheme == right.scheme &&
        normalized_host(left.host) == normalized_host(right.host) &&
        left.port == right.port
    end

    def normalized_login_error(error)
      error.to_s.scrub("?").gsub(/[[:cntrl:]]+/, " ").squish
        .truncate(MAX_LOGIN_ERROR_LENGTH, omission: "...").presence
    end

    def cache_auth(signature, auth)
      @auth_cache = {
        signature: signature,
        auth: auth,
        expires_at: Time.current + AUTH_TTL_SECONDS
      }
    end

    def ensure_configured!
      raise NotConfiguredError, "Z-Library is not configured" unless configured?
      configured_uris
    end

    def credential_signature
      Digest::SHA256.hexdigest([
        SettingsService.get(:zlibrary_enabled, default: false),
        SettingsService.get(:zlibrary_url).to_s,
        SettingsService.get(:zlibrary_email).to_s,
        SettingsService.get(:zlibrary_password).to_s,
        SettingsService.get(:zlibrary_remix_userid).to_s,
        SettingsService.get(:zlibrary_remix_userkey).to_s
      ].join("\0"))
    end

    def configured_uris
      raw_url = SettingsService.get(:zlibrary_url).to_s
      raise ConfigurationError, "Z-Library URL is not configured" if raw_url.blank?

      raw_url.split(/[,\s]+/).filter_map do |url|
        normalized_uri(url.strip)
      end.uniq { |uri| [ uri.scheme, uri.host, uri.port ] }.tap do |uris|
        raise ConfigurationError, "At least one valid Z-Library URL is required" if uris.empty?
      end
    end

    def normalized_uri(url)
      return if url.blank?

      uri = URI.parse(url)
      unless ALLOWED_DOWNLOAD_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise ConfigurationError, "Z-Library URL must be a valid http or https URL"
      end

      if uri.path.present? && uri.path != "/"
        raise ConfigurationError, "Z-Library URL must not include a path"
      end

      if uri.query.present? || uri.fragment.present? || uri.userinfo.present?
        raise ConfigurationError, "Z-Library URL must only include the site origin"
      end

      uri
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "Z-Library URL is invalid: #{e.message}"
    end

    def with_authenticated_retry(context:, after_attempt: nil)
      attempted_retry = false

      begin
        auth = login(after_attempt: after_attempt)
        using_cached_auth = @last_auth_from_cache

        yield auth
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError,
             JSON::ParserError, Error => e
        raise ConnectionError, "Failed to connect to Z-Library: #{e.message}" if transport_error?(e) && attempted_retry

        unless using_cached_auth && !attempted_retry
          raise ConnectionError, "Failed to connect to Z-Library: #{e.message}" if transport_error?(e)

          raise
        end

        Rails.logger.debug "[ZLibraryClient] #{context} failed on cached domain: #{e.message}"
        @auth_cache = nil
        attempted_retry = true
        retry
      end
    end

    def transport_error?(error)
      error.is_a?(Faraday::ConnectionFailed) ||
        error.is_a?(Faraday::TimeoutError) ||
        error.is_a?(Faraday::SSLError)
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/x-www-form-urlencoded"
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def cookie_header(auth)
      "remix_userid=#{auth[:remix_userid]}; remix_userkey=#{auth[:remix_userkey]}"
    end

    def fetch_search_results(auth, query:, file_types:, limit:, language:, after_attempt:)
      payload = [ [ "message", query ], [ "limit", limit.to_s ] ]
      Array(file_types).each { |ext| payload << [ "extensions[]", ext ] }
      payload << [ "languages[]", language ] if language.present?

      exchange = post_search_exchange(auth, payload, after_attempt: after_attempt)
      response = usable_search_response(exchange)
      walled_domains = []
      walled_domains << auth[:domain] if search_exchange_walled?(exchange)

      if response.nil? || search_html_fallback_response?(response)
        alternate_results = search_eapi_alternate_domains(
          auth,
          payload,
          limit,
          after_attempt: after_attempt,
          walled_domains: walled_domains
        )
        return alternate_results if alternate_results
      end

      if response.nil?
        if search_exchange_walled?(exchange)
          return html_search_or_bot_wall(
            auth,
            walled_domains,
            query: query,
            file_types: file_types,
            limit: limit,
            language: language,
            after_attempt: after_attempt
          )
        end

        raise ConnectionError, "Z-Library search failed: #{exchange[:error].presence || "no response"}"
      end

      if search_html_fallback_response?(response)
        Rails.logger.warn "[ZLibraryClient] eAPI search unavailable; falling back to HTML search"
        return search_html(
          auth,
          query,
          file_types: file_types,
          limit: limit,
          language: language,
          after_attempt: after_attempt
        )
      end

      remember_search_origin!(auth, exchange)
      data = parse_response(response, context: "search")
      parse_search_results(data.fetch("books", []), limit)
    end

    def post_search_exchange(auth, payload, after_attempt: nil)
      follow_exchange(
        "#{auth[:base_url]}/eapi/book/search",
        method: :post,
        body: URI.encode_www_form(payload),
        after_attempt: after_attempt,
        seed_cookies: cookie_header(auth)
      )
    end

    def get_file_response(auth, id:, hash:)
      connection.get("#{auth[:base_url]}/eapi/book/#{id}/#{hash}/file") do |req|
        req.headers["Cookie"] = cookie_header(auth)
      end
    end

    def parse_response(response, context:)
      case response.status
      when 200
        data = parse_json_body(response)
        unless data.is_a?(Hash)
          raise Error, "Z-Library #{context} returned an invalid response"
        end
        if data["success"] == 0
          error_message = data["error"].presence || "unknown Z-Library error"
          raise Error, "Z-Library #{context} failed: #{error_message}"
        end
        data
      when 401, 403
        raise AuthenticationError, "Invalid Z-Library credentials"
      when 429
        raise RateLimitError, "Z-Library rate limit exceeded"
      else
        raise ConnectionError, "Z-Library #{context} failed with status #{response.status}"
      end
    end

    def parse_json_body(response)
      return response.body unless response.body.is_a?(String)

      JSON.parse(response.body)
    end

    def search_eapi_alternate_domains(current_auth, payload, limit, after_attempt: nil, walled_domains: nil)
      each_alternate_auth(current_auth, after_attempt: after_attempt) do |auth|
        exchange = post_search_exchange(auth, payload, after_attempt: after_attempt)
        if search_exchange_walled?(exchange)
          walled_domains << auth[:domain] if walled_domains
          next
        end

        response = usable_search_response(exchange)
        next if response.nil? || search_html_fallback_response?(response)

        remember_search_origin!(auth, exchange)
        data = parse_response(response, context: "search")
        return parse_search_results(data.fetch("books", []), limit)
      end

      nil
    end

    def get_download_url_from_alternate_domains(current_auth, id:, hash:)
      each_alternate_auth(current_auth) do |auth|
        response = get_file_response(auth, id: id, hash: hash)
        next if download_html_fallback_response?(response)

        data = parse_response(response, context: "download lookup")
        download_link = data.dig("file", "downloadLink")
        next if download_link.blank?

        validate_download_url!(download_link)
        return download_link
      end

      nil
    end

    def each_alternate_auth(current_auth, after_attempt: nil)
      signature = credential_signature

      configured_uris.each do |uri|
        base_url = uri.to_s.delete_suffix("/")
        next if base_url == current_auth[:base_url]
        healthy_uri = probe_domain(uri, after_attempt: after_attempt)
        next unless healthy_uri.is_a?(URI::HTTP)
        next if healthy_uri.to_s.delete_suffix("/") == current_auth[:base_url]

        auth = auth_for_domain(healthy_uri, after_attempt: after_attempt)
        next if auth.nil? || (auth.is_a?(Hash) && auth[:error].present?)

        Rails.logger.info "[ZLibraryClient] Retrying eAPI via #{auth[:domain]}"
        cache_auth(signature, auth)
        yield auth
      rescue JSON::ParserError, Faraday::Error, Error => e
        Rails.logger.debug "[ZLibraryClient] eAPI retry failed on #{uri.host}: #{e.message}"
      end
    end

    def search_html(auth, query, file_types:, limit:, language:, after_attempt: nil)
      result = read_html_search(
        auth,
        query: query,
        file_types: file_types,
        limit: limit,
        language: language,
        after_attempt: after_attempt
      )
      return result unless result == :bot_wall

      raise_search_bot_wall!([ auth[:domain] ])
    end

    def html_search_or_bot_wall(auth, walled_domains, query:, file_types:, limit:, language:, after_attempt:)
      result = read_html_search(
        auth,
        query: query,
        file_types: file_types,
        limit: limit,
        language: language,
        after_attempt: after_attempt
      )
      return result unless result == :bot_wall

      walled_domains << auth[:domain]
      raise_search_bot_wall!(walled_domains)
    end

    def read_html_search(auth, query:, file_types:, limit:, language:, after_attempt:)
      exchange = follow_exchange(
        html_search_url(auth[:base_url], query, file_types: file_types, language: language),
        method: :get,
        after_attempt: after_attempt,
        seed_cookies: cookie_header(auth)
      )
      return :bot_wall if search_exchange_walled?(exchange)

      response = exchange[:response]
      unless response&.status == 200
        raise ConnectionError, "Z-Library HTML search failed with status #{response&.status || exchange[:error]}"
      end

      remember_search_origin!(auth, exchange)
      parse_html_search_results(response_body_string(response), limit)
    end

    # A same-URL 307 whose cookie jar never changes comes back as a redirect loop.
    def search_exchange_walled?(exchange)
      return true if exchange[:bot_wall]
      return true if exchange[:error] == "redirect loop"

      response = exchange[:response]
      return false unless response

      response.status == BOT_WALL_HTTP_STATUS || bot_wall_response?(response)
    end

    def usable_search_response(exchange)
      return if search_exchange_walled?(exchange)

      response = exchange[:response]
      return if response.nil? || login_redirect?(response)

      response
    end

    def remember_search_origin!(auth, exchange)
      final_url = exchange[:url].to_s
      return if final_url.blank?

      final_uri = URI.parse(final_url)
      base_url = login_base_url(final_uri, URI.parse(auth[:base_url]))
      return if base_url == auth[:base_url].to_s.delete_suffix("/")

      cache_auth(credential_signature, auth.merge(domain: final_uri.host, base_url: base_url))
    end

    def raise_search_bot_wall!(domains)
      names = Array(domains).map { |domain| domain.to_s }.uniq
      message = "Z-Library search is bot-walled (#{names.join(', ')}). Configure another domain that serves the eAPI."
      Rails.logger.error "[ZLibraryClient] #{message}"
      raise ConnectionError, message
    end

    def observe_search_attempt(after_attempt)
      yield
    ensure
      ensure_search_continues!(after_attempt)
    end

    def ensure_search_continues!(after_attempt)
      return if after_attempt.nil? || after_attempt.call

      raise SearchCancelled, "Search ownership changed"
    end

    def html_search_url(base_url, query, file_types:, language:)
      params = []
      Array(file_types).each { |ext| params << [ "extensions[]", ext.to_s.upcase ] }
      params << [ "languages[]", language ] if language.present?

      encoded_query = CGI.escape(query.to_s).gsub("+", "%20")
      query_string = URI.encode_www_form(params)

      [ "#{base_url}/s/#{encoded_query}", query_string.presence ].compact.join("?")
    end

    def parse_html_search_results(html, limit)
      doc = Nokogiri::HTML(html)
      return [] if doc.at_css(".notFound")

      doc.css("z-bookcard").first(limit).filter_map do |card|
        parse_html_book_card(card)
      end
    end

    def parse_html_book_card(card)
      href = card["href"].to_s
      id = card["id"].presence || href[%r{/book/(\d+)}, 1]
      hash = href[%r{/book/\d+/([^/?#]+)}, 1]
      return if id.blank? || hash.blank?

      Result.new(
        id: id,
        hash: hash,
        title: card.at_css('[slot="title"]')&.text&.strip.presence || "Unknown",
        author: html_card_author(card),
        year: card["year"]&.to_i&.nonzero?,
        file_type: card["extension"]&.to_s&.downcase,
        file_size: parse_file_size(card["filesize"]),
        language: normalize_language(card["language"])
      )
    end

    def html_card_author(card)
      card.at_css('[slot="author"]')&.text.to_s.split(";").map(&:strip).reject(&:blank?).join(", ").presence
    end

    def get_html_download_url(auth, id:, hash:)
      response = connection.get("#{auth[:base_url]}/book/#{id}/#{hash}") do |req|
        req.headers["Cookie"] = cookie_header(auth)
      end

      unless response.status == 200
        raise ConnectionError, "Z-Library HTML download lookup failed with status #{response.status}"
      end

      doc = Nokogiri::HTML(response.body.to_s)
      download_link = doc.at_css("a.addDownloadedBook[href]")&.[]("href").presence ||
        doc.at_css('a[href^="/dl/"], a[href*="/dl/"]')&.[]("href").presence
      raise Error, "Z-Library did not return a download link" if download_link.blank?

      absolute_url(auth[:base_url], download_link).tap { |url| validate_download_url!(url) }
    end

    def absolute_url(base_url, url)
      URI.join("#{base_url}/", url).to_s
    rescue URI::InvalidURIError => e
      raise Error, "Z-Library returned an invalid download URL: #{e.message}"
    end

    def search_html_fallback_response?(response)
      response.status == 400 || eapi_html_response?(response) || generic_zlibrary_error?(response)
    end

    def download_html_fallback_response?(response)
      response.status == 400 || eapi_html_response?(response) || generic_zlibrary_error?(response)
    end

    def generic_zlibrary_error?(response)
      return false unless response.status == 200

      data = parse_json_body(response)
      data["success"] == 0 && data["error"].to_s.match?(/Some errors? occurr?ed/i)
    rescue JSON::ParserError => error
      RemoteResult::Failed.new(error)
    end

    def eapi_html_response?(response)
      return false unless response.status == 200

      content_type = response.headers["content-type"].to_s
      body = response.body.to_s.lstrip

      content_type.match?(%r{text/html|application/xhtml\+xml}i) ||
        body.start_with?("<!doctype", "<!DOCTYPE", "<html", "<HTML")
    end

    def validate_download_url!(url)
      uri = URI.parse(url)
      unless ALLOWED_DOWNLOAD_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise Error, "Z-Library returned an invalid download URL"
      end
    rescue URI::InvalidURIError => e
      raise Error, "Z-Library returned an invalid download URL: #{e.message}"
    end

    def parse_file_size(value)
      text = value.to_s.strip
      return if text.blank?

      number, unit = text.match(/\A([\d.]+)\s*([kmgt]?b)?/i)&.captures
      return text.to_i if number.blank?

      multiplier = case unit.to_s.downcase
      when "kb" then 1024
      when "mb" then 1024**2
      when "gb" then 1024**3
      when "tb" then 1024**4
      else 1
      end

      (number.to_f * multiplier).round
    end

    def parse_search_results(books, limit)
      Array(books).first(limit).filter_map do |book|
        id = book["id"]&.to_s
        hash = book["hash"]&.to_s
        next if id.blank? || hash.blank?

        Result.new(
          id: id,
          hash: hash,
          title: book["name"].presence || book["title"].presence || "Unknown",
          author: book["author"].presence,
          year: book["year"]&.to_i&.nonzero?,
          file_type: book["extension"]&.to_s&.downcase,
          file_size: book["filesize"]&.to_i&.nonzero?,
          language: normalize_language(book["language"])
        )
      end
    end

    def normalize_language(language)
      value = language.to_s.strip
      return if value.blank?

      direct_match = ReleaseParserService.language_info(value)
      return value if direct_match

      matched_code, = ReleaseParserService::LANGUAGES.find do |code, info|
        code.casecmp?(value) || info[:name].casecmp?(value)
      end

      matched_code || value.downcase
    end
  end
end
