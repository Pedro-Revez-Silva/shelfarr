# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "faraday"
require "set"
require "securerandom"
require "time"
require "tzinfo"
require "uri"

class EbooksComClient
  class Error < StoreProviderError; end
  class ConnectionError < Error; end
  class NotConfiguredError < Error; end
  class RateLimitError < Error; end

  Result = Data.define(
    :id, :title, :author, :isbns, :language, :formats, :market,
    :drm_type, :price_amount, :price_currency, :localized_price,
    :storefront_url, :checkout_url, :cover_url, :quoted_at
  )

  BASE_URL = "https://api.ebooks.com"
  ALLOWED_STORE_HOSTS = %w[ebooks.com www.ebooks.com].freeze
  MAX_RESULTS = 10
  MAX_UPSTREAM_RESULTS = 100
  MAX_QUERY_LENGTH = 150
  MAX_RESPONSE_BYTES = 1.megabyte
  MAX_JSON_NESTING = 20
  MAX_EXTERNAL_ID_LENGTH = 32
  MAX_TITLE_LENGTH = 500
  MAX_AUTHOR_LENGTH = 300
  MAX_ISBNS = 20
  MAX_AUTHORS = 20
  MAX_DRM_TYPE_LENGTH = 64
  MAX_LOCALIZED_PRICE_LENGTH = 64
  MAX_URL_LENGTH = 2_048
  MAX_LANGUAGE_NAME_LENGTH = 100
  # Expire cached catalog payloads before persisted offers become stale. This
  # prevents reconciliation from restoring an already-expired cached quote.
  CACHE_TTL = 23.hours
  RATE_LIMIT_CACHE_KEY = "ebooks_com:v2:rate_limit_until"
  REQUEST_LOCK_CACHE_KEY = "ebooks_com:v2:request_lock"
  REQUEST_LOCK_TTL = 30.seconds
  REQUEST_LOCK_WAIT = REQUEST_LOCK_TTL + 1.second
  REQUEST_LOCK_POLL_INTERVAL = 0.05
  DEFAULT_RATE_LIMIT_COOLDOWN = 15.minutes.to_i
  MAX_RATE_LIMIT_COOLDOWN = 6.hours.to_i
  MIN_RATE_LIMIT_COOLDOWN = 1
  REQUEST_MUTEX = Mutex.new
  USER_AGENT = "Shelfarr/1.0 (+https://github.com/Pedro-Revez-Silva/shelfarr)"

  class << self
    def configured?
      SettingsService.ebooks_com_configured?
    end

    def valid_country_code?(value)
      code = value.to_s.strip.upcase
      code.match?(/\A[A-Z]{2}\z/) && TZInfo::Country.all_codes.include?(code)
    rescue TZInfo::InvalidCountryCode
      false
    end

    def search(title:, author: nil, isbn: nil, language: nil, limit: nil)
      ensure_configured!
      query_title = api_query_value(title)
      query_author = api_query_value(author)
      return [] if query_title.blank? && isbn.blank?

      market = country_code
      raise NotConfiguredError, "eBooks.com buyer country is invalid" unless valid_country_code?(market)

      parsed_results = []
      normalized_isbn = valid_isbn(isbn)
      if normalized_isbn.present?
        isbn_results = parse_results(
          fetch_results("/v2/#{market}/book/isbn/#{normalized_isbn}"),
          market: market
        )
        parsed_results.concat(isbn_results)
      end

      if query_title.present? && !exact_isbn_offer?(parsed_results, normalized_isbn, language)
        parsed_results.concat(parse_results(fetch_results("/v2/#{market}/book/search", {
          title: query_title,
          author: query_author,
          drmFree: true
        }.compact), market: market))
      end

      parsed_results = parsed_results
        .uniq(&:id)
        .select { |result| language_matches?(result, language) }

      scored_results = parsed_results.filter_map do |result|
        score = relevance_score(result, title: query_title, author: query_author, isbn: normalized_isbn)
        next if score < 65

        [ result, score ]
      end

      scored_results
        .sort_by { |result, score| [ -score, result.price_amount || Float::INFINITY, result.id.to_s ] }
        .first(search_limit(limit))
        .map(&:first)
    end

    def test_connection
      ensure_configured!
      market = country_code
      raise NotConfiguredError, "eBooks.com buyer country is invalid" unless valid_country_code?(market)

      fetch_uncached_results(
        "/v2/#{market}/book/search",
        { title: "The Moonstone", drmFree: true },
        allow_not_found: false
      )
      true
    rescue Error => e
      Rails.logger.error "[EbooksComClient] Connection test failed (#{e.class})"
      false
    end

    def buyer_country_code
      country_code
    end

    def reset_connection!
      REQUEST_MUTEX.synchronize { @connection = nil }
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "eBooks.com store offers are not configured" unless configured?
    end

    def country_code
      SettingsService.get(:ebooks_com_country_code).to_s.strip.upcase
    end

    def search_limit(limit)
      requested = limit || SettingsService.get(:ebooks_com_search_limit, default: 5)
      requested.to_i.clamp(1, MAX_RESULTS)
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |faraday|
        faraday.request :url_encoded
        faraday.headers["Accept"] = "application/json"
        faraday.headers["User-Agent"] = USER_AGENT
        faraday.options.timeout = 15
        faraday.options.open_timeout = 5
        faraday.adapter Faraday.default_adapter
      end
    end

    def fetch_results(path, params = {})
      cache_key = response_cache_key(path, params)
      cached_results = read_valid_cached_results(cache_key)
      return cached_results unless cached_results.nil?

      REQUEST_MUTEX.synchronize do
        with_shared_request_lock do
          cached_results = read_valid_cached_results(cache_key)
          next cached_results unless cached_results.nil?

          ensure_not_rate_limited!
          results = perform_request(path, params)
          Rails.cache.write(cache_key, results, expires_in: CACHE_TTL)
          results
        end
      end
    end

    def fetch_uncached_results(path, params = {}, allow_not_found: true, **query_params)
      params = params.merge(query_params)
      REQUEST_MUTEX.synchronize do
        with_shared_request_lock do
          ensure_not_rate_limited!
          perform_request(path, params, allow_not_found: allow_not_found)
        end
      end
    end

    def perform_request(path, params, allow_not_found: true)
      response_body = +"".b
      response = connection.get(path, params) do |request|
        request.options.on_data = proc do |chunk, _downloaded, env|
          ensure_response_within_limit!(env, response_body, chunk)
          response_body << chunk
        end
      end

      case response.status
      when 200
        body = parse_response_body(response_body)
        raise ConnectionError, "eBooks.com returned an invalid response" unless body.is_a?(Hash)

        results = body["results"]
        return [] if results.nil?

        raise ConnectionError, "eBooks.com returned invalid results" unless results.is_a?(Array)
        if results.size > MAX_UPSTREAM_RESULTS
          raise ConnectionError, "eBooks.com returned too many results"
        end
        raise ConnectionError, "eBooks.com returned an invalid book result" unless results.all?(Hash)

        checked_at = Time.current
        results.map { |book| compact_book_payload(book, quoted_at: checked_at) }
      when 404
        return [] if allow_not_found

        raise ConnectionError, "eBooks.com catalog endpoint was not found"
      when 429
        cooldown = retry_after_seconds(response.headers["Retry-After"])
        remember_rate_limit!(cooldown)
        raise RateLimitError, "eBooks.com rate limit exceeded; retry in #{cooldown} seconds"
      else
        raise ConnectionError, "eBooks.com request failed with status #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to eBooks.com (#{e.class})"
    rescue Faraday::ParsingError, JSON::ParserError, EncodingError
      raise ConnectionError, "eBooks.com returned malformed JSON"
    end

    def ensure_response_within_limit!(env, accumulated_body, chunk)
      raw_length = env.response_headers["content-length"].to_s
      declared_length = if raw_length.bytesize <= 32
        Integer(raw_length, exception: false)
      end
      if raw_length.bytesize > 32 || declared_length&.>(MAX_RESPONSE_BYTES) ||
          chunk.bytesize > MAX_RESPONSE_BYTES - accumulated_body.bytesize
        raise ConnectionError, "eBooks.com response exceeds the #{MAX_RESPONSE_BYTES / 1.megabyte} MB limit"
      end
    end

    def parse_response_body(body)
      JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: MAX_JSON_NESTING)
    end

    def response_cache_key(path, params)
      digest = Digest::SHA256.hexdigest([ path, params.sort_by { |key, _| key.to_s } ].to_json)
      "ebooks_com:v3:#{digest}"
    end

    def read_valid_cached_results(cache_key)
      cached = Rails.cache.read(cache_key)
      return if cached.nil?
      return cached if valid_cached_results?(cached)

      Rails.cache.delete(cache_key)
      nil
    end

    def valid_cached_results?(value)
      value.is_a?(Array) && value.size <= MAX_UPSTREAM_RESULTS && value.all? do |book|
        book.is_a?(Hash) && book.keys.all? { |key| key.is_a?(String) }
      end
    end

    # Solid Cache makes this lease shared by every Puma process. The in-process
    # mutex remains useful for MemoryStore/NullStore installations and avoids
    # unnecessary cache polling between local threads.
    def with_shared_request_lock
      token = SecureRandom.hex(16)
      deadline = monotonic_time + REQUEST_LOCK_WAIT

      loop do
        if Rails.cache.write(REQUEST_LOCK_CACHE_KEY, token, expires_in: REQUEST_LOCK_TTL, unless_exist: true)
          begin
            return yield
          ensure
            Rails.cache.delete(REQUEST_LOCK_CACHE_KEY) if Rails.cache.read(REQUEST_LOCK_CACHE_KEY) == token
          end
        end

        if monotonic_time >= deadline
          raise ConnectionError, "eBooks.com catalog is busy; try again shortly"
        end

        sleep REQUEST_LOCK_POLL_INTERVAL
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ensure_not_rate_limited!
      retry_at = Float(Rails.cache.read(RATE_LIMIT_CACHE_KEY), exception: false)
      return unless retry_at&.finite?
      return unless retry_at > Time.current.to_f

      remaining = (retry_at - Time.current.to_f).ceil.clamp(MIN_RATE_LIMIT_COOLDOWN, MAX_RATE_LIMIT_COOLDOWN)
      raise RateLimitError, "eBooks.com rate limit cooldown active; retry in #{remaining} seconds"
    end

    def remember_rate_limit!(seconds)
      retry_at = Time.current + seconds
      Rails.cache.write(RATE_LIMIT_CACHE_KEY, retry_at.to_f, expires_in: seconds)
    end

    def retry_after_seconds(value)
      raw_value = value.to_s.byteslice(0, 128).to_s.strip
      seconds = Integer(raw_value, exception: false)
      seconds ||= retry_after_http_date(raw_value)
      seconds ||= DEFAULT_RATE_LIMIT_COOLDOWN
      seconds.clamp(MIN_RATE_LIMIT_COOLDOWN, MAX_RATE_LIMIT_COOLDOWN)
    end

    def retry_after_http_date(value)
      return if value.blank?

      (Time.httpdate(value) - Time.current).ceil
    rescue ArgumentError
      nil
    end

    def parse_results(books, market:)
      books.filter_map do |book|
        parse_result(book, market: market)
      rescue ArgumentError, NoMethodError, TypeError => e
        Rails.logger.warn "[EbooksComClient] Ignoring malformed book result (#{e.class})"
        nil
      end
    end

    def parse_result(book, market:)
      return unless book.is_a?(Hash)

      drm = book["drm"].is_a?(Hash) ? book["drm"] : {}
      return unless drm["drmFreeAvailable"] == true

      id = book_identifier(book["id"])
      title = bounded_text(book["title"], max_length: MAX_TITLE_LENGTH)
      formats = available_formats(book["formats"])
      storefront_url = safe_store_url(book["storefrontUrl"])
      return if id.blank? || title.blank? || formats.empty? || storefront_url.blank?
      return unless store_path_matches?(storefront_url, market, [ "book", id ])

      price = book["price"].is_a?(Hash) ? book["price"] : {}
      return unless price_market_matches?(price, market)
      quoted_at = quote_time(book["_quotedAt"])
      return unless quoted_at

      price_amount = decimal_value(price["value"])
      price_currency = currency_code(price["currency"])
      unless price_amount && price_currency
        price_amount = nil
        price_currency = nil
      end
      localized_price = if price_amount && price_currency
        bounded_text(price["localisedValue"], max_length: MAX_LOCALIZED_PRICE_LENGTH)
      end

      Result.new(
        id: id,
        title: title,
        author: primary_author(book["authors"]),
        isbns: parsed_isbns(book["isbns"]),
        language: language_code(book["language"]),
        formats: formats,
        market: market,
        drm_type: bounded_text(drm["drmFreeType"], max_length: MAX_DRM_TYPE_LENGTH),
        price_amount: price_amount,
        price_currency: price_currency,
        localized_price: localized_price,
        storefront_url: storefront_url,
        checkout_url: checkout_store_url(book["addToCartUrl"], market, id),
        cover_url: safe_cover_url(book["coverImageUrl"]),
        quoted_at: quoted_at
      )
    end

    def price_market_matches?(price, market)
      raw_market = price["countryCode"]
      return true if raw_market.nil?
      return false unless raw_market.is_a?(String)

      reported_market = raw_market.strip.upcase
      reported_market.blank? || reported_market == market
    end

    def available_formats(value)
      formats = value.is_a?(Hash) ? value : {}
      %w[epub pdf].select { |format| formats[format] == true }
    end

    def primary_author(value)
      return unless value.is_a?(Array) && value.size <= MAX_AUTHORS

      authors = value.select { |candidate| candidate.is_a?(Hash) }
      author = authors.find do |candidate|
        candidate["type"].is_a?(String) && candidate["type"].casecmp?("author")
      end || authors.first
      bounded_text(author&.dig("name"), max_length: MAX_AUTHOR_LENGTH)
    end

    def language_code(value)
      language = value.is_a?(Hash) ? value : {}
      name = bounded_text(language["name"], max_length: MAX_LANGUAGE_NAME_LENGTH)
      return if name.blank?

      ReleaseParserService::LANGUAGES.find do |_, info|
        info[:name].casecmp?(name)
      end&.first
    end

    def exact_isbn_offer?(results, isbn, language)
      return false if isbn.blank?

      results.any? do |result|
        result.isbns.include?(isbn) && language_matches?(result, language)
      end
    end

    def language_matches?(result, requested_language)
      requested = requested_language.to_s.strip
      requested.blank? || result.language.blank? || result.language == requested
    end

    def relevance_score(result, title:, author:, isbn:)
      return 100 if isbn.present? && result.isbns.include?(isbn)

      title_score = text_similarity(title, result.title, allow_containment: true)
      return 0 if title_score < 65
      if author.blank?
        exact_title = normalize_text(title) == normalize_text(result.title)
        multi_word_title = normalize_text(title).split.size >= 2
        return exact_title || (multi_word_title && title_score >= 80) ? title_score : 0
      end

      author_score = text_similarity(author, result.author, allow_containment: true)
      return 0 if author_score < 60

      ((title_score * 0.75) + (author_score * 0.25)).round
    end

    def text_similarity(expected, actual, allow_containment:)
      expected = normalize_text(expected)
      actual = normalize_text(actual)
      return 0 if expected.blank? || actual.blank?
      return 100 if expected == actual
      return 92 if allow_containment && meaningful_containment?(expected, actual)

      expected_trigrams = trigrams(expected)
      actual_trigrams = trigrams(actual)
      return 0 if expected_trigrams.empty? || actual_trigrams.empty?

      ((expected_trigrams.intersection(actual_trigrams).size.to_f /
        expected_trigrams.union(actual_trigrams).size) * 100).round
    end

    def meaningful_containment?(expected, actual)
      return false unless expected.include?(actual) || actual.include?(expected)

      shorter = expected.length <= actual.length ? expected : actual
      shorter.length >= 6
    end

    def normalize_text(value)
      value.to_s.downcase.gsub(/[^\p{Alnum}\s]/u, " ").squish
    end

    def trigrams(value)
      padded = "  #{value}  "
      (0..padded.length - 3).map { |index| padded[index, 3] }.to_set
    end

    def normalize_isbn(value)
      value.to_s.upcase.gsub(/[^0-9X]/, "")
    end

    def valid_isbn(value)
      return unless value.is_a?(String)

      normalized = normalize_isbn(value)
      normalized if valid_isbn_checksum?(normalized)
    end

    def api_query_value(value)
      bounded = value.to_s.strip.truncate(MAX_QUERY_LENGTH, omission: "")
      return if bounded.blank? || unsupported_characters?(bounded)

      bounded
    end

    def decimal_value(value)
      return unless value.is_a?(Numeric) || value.is_a?(String)

      raw_value = value.to_s
      return if raw_value.blank? || raw_value.bytesize > 32

      decimal = BigDecimal(raw_value)
      return unless decimal.finite? && decimal >= 0 && decimal <= 99_999_999

      decimal
    rescue ArgumentError, TypeError
      nil
    end

    def safe_store_url(value)
      safe_https_url(value, allowed_hosts: ALLOWED_STORE_HOSTS)
    end

    def checkout_store_url(value, market, id)
      url = safe_store_url(value)
      url if store_path_matches?(url, market, [ "cart", "add", id ])
    end

    def safe_cover_url(value)
      safe_https_url(value, allowed_hosts: %w[image.ebooks.com])
    end

    def store_path_matches?(value, market, expected_segments)
      uri = URI.parse(value.to_s)
      segments = uri.path.to_s.split("/").reject(&:blank?)
      locale = segments.shift
      match = locale&.match(/\A[a-z]{2}-([a-z]{2})\z/i)
      match && match[1].upcase == market && segments.first(expected_segments.size) == expected_segments
    rescue URI::InvalidURIError
      false
    end

    def safe_https_url(value, allowed_hosts:)
      return unless value.is_a?(String)

      raw_value = value.strip
      return if raw_value.blank? || raw_value.bytesize > MAX_URL_LENGTH || unsupported_characters?(raw_value)

      uri = URI.parse(raw_value)
      return unless uri.scheme == "https" && allowed_hosts.include?(uri.host&.downcase) && uri.userinfo.blank?
      return unless uri.port == 443

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def compact_book_payload(book, quoted_at:)
      {
        "id" => book["id"],
        "title" => book["title"],
        "storefrontUrl" => book["storefrontUrl"],
        "addToCartUrl" => book["addToCartUrl"],
        "coverImageUrl" => book["coverImageUrl"],
        "isbns" => book["isbns"],
        "authors" => compact_hash_array(book["authors"], %w[name type]),
        "price" => compact_hash(book["price"], %w[currency countryCode value localisedValue]),
        "drm" => compact_hash(book["drm"], %w[drmFreeAvailable drmFreeType]),
        "formats" => compact_hash(book["formats"], %w[epub pdf]),
        "language" => compact_hash(book["language"], %w[name]),
        "_quotedAt" => quoted_at
      }
    end

    def compact_hash(value, keys)
      value.is_a?(Hash) ? value.slice(*keys) : value
    end

    def compact_hash_array(value, keys)
      return value unless value.is_a?(Array)
      return [] if value.size > MAX_AUTHORS

      value.map { |item| item.is_a?(Hash) ? item.slice(*keys) : item }
    end

    def parsed_isbns(value)
      return [] unless value.is_a?(Array) && value.size <= MAX_ISBNS

      value.filter_map { |candidate| valid_isbn(candidate) }.uniq
    end

    def book_identifier(value)
      integer = if value.is_a?(Integer)
        value
      elsif value.is_a?(String) && value.match?(/\A[0-9]{1,#{MAX_EXTERNAL_ID_LENGTH}}\z/)
        Integer(value, 10)
      end
      integer.to_s if integer&.between?(1, 2_147_483_647)
    end

    def currency_code(value)
      return unless value.is_a?(String)

      code = value.to_s.strip.upcase
      code if code.match?(/\A[A-Z]{3}\z/)
    end

    def bounded_text(value, max_length:)
      return unless value.is_a?(String)

      text = value.strip
      return if text.blank? || text.length > max_length || text.bytesize > max_length * 4
      return if unsupported_characters?(text)

      text
    end

    def unsupported_characters?(value)
      !value.valid_encoding? || value.match?(/[\p{Cc}\p{Cf}]/u)
    end

    def quote_time(value)
      return unless value.respond_to?(:to_time)

      time = value.to_time.in_time_zone
      time if time.between?(CACHE_TTL.ago, 5.minutes.from_now)
    rescue ArgumentError, RangeError
      nil
    end

    def valid_isbn_checksum?(value)
      case value.length
      when 10
        return false unless value.match?(/\A[0-9]{9}[0-9X]\z/)

        value.chars.each_with_index.sum do |character, index|
          digit = character == "X" ? 10 : character.to_i
          digit * (10 - index)
        end.modulo(11).zero?
      when 13
        return false unless value.match?(/\A[0-9]{13}\z/)

        value.chars.each_with_index.sum do |character, index|
          character.to_i * (index.even? ? 1 : 3)
        end.modulo(10).zero?
      else
        false
      end
    end
  end
end
