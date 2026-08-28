# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "timeout"

# Client for interacting with the Hardcover GraphQL API
# https://hardcover.app/account/api
class HardcoverClient
  BASE_URL = "https://api.hardcover.app/v1/graphql"
  RATE_LIMIT_CACHE_VERSION = 1
  RATE_LIMIT_BUCKETS = %i[retry minute daily].freeze
  DEFAULT_RATE_LIMIT_COOLDOWN = 60
  MIN_RATE_LIMIT_COOLDOWN = 1
  MAX_RATE_LIMIT_COOLDOWN = 25.hours.to_i
  MAX_RATE_LIMIT_HEADER_BYTES = 4.kilobytes
  RATE_LIMIT_STATE_MUTEX = Mutex.new
  REQUEST_MUTEX = Mutex.new
  HARD_REQUEST_TIMEOUT = 35.seconds
  REQUEST_LOCK_TTL = HARD_REQUEST_TIMEOUT + 10.seconds
  REQUEST_LOCK_WAIT = REQUEST_LOCK_TTL + 1.second
  REQUEST_LOCK_POLL_INTERVAL = 0.05

  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error
    attr_reader :retry_after, :retry_at

    def initialize(message, retry_after: nil)
      @retry_after = retry_after
      @retry_at = Time.current + retry_after if retry_after
      super(message)
    end
  end
  class NotFoundError < Error; end
  class NotConfiguredError < Error; end

  Credential = Data.define(:authorization_header, :digest)

  # Data structures for API responses
  SearchResult = Data.define(
    :id, :title, :author, :description, :release_year,
    :cover_url, :has_audiobook, :has_ebook, :series_name, :series_position
  ) do
    def work_id
      "hardcover:#{id}"
    end

    # Compatibility with OpenLibrary patterns
    def first_publish_year
      release_year
    end

    def cover_id
      nil # Hardcover provides full URLs
    end
  end

  BookDetails = Data.define(
    :id, :title, :author, :description, :release_year,
    :cover_url, :has_audiobook, :has_ebook, :pages, :genres, :series_id, :series_name, :series_position
  ) do
    def work_id
      "hardcover:#{id}"
    end
  end

  class << self
    def configured?
      SettingsService.get(:hardcover_enabled, default: true) && SettingsService.hardcover_configured?
    end

    # Search for books by query
    # Returns array of SearchResult
    def search(query, limit: nil)
      ensure_configured!
      limit ||= SettingsService.get(:hardcover_search_limit, default: 10)

      query_string = <<~GRAPHQL
        query SearchBooks($query: String!, $perPage: Int!) {
          search(query: $query, query_type: "Book", per_page: $perPage) {
            results
          }
        }
      GRAPHQL

      response = execute_query(query_string, { query: query, perPage: limit })

      # Debug: log full response structure to understand format
      Rails.logger.info "[HardcoverClient] Response keys: #{response.keys rescue 'not a hash'}"
      Rails.logger.info "[HardcoverClient] Search data: #{response.dig('data', 'search')&.keys rescue 'not accessible'}"

      raw_results = response.dig("data", "search", "results")
      results = extract_hits(raw_results)

      Rails.logger.info "[HardcoverClient] Search '#{query}' returned #{results.size} results"
      if results.any?
        Rails.logger.info "[HardcoverClient] First result class: #{results.first.class}"
        Rails.logger.info "[HardcoverClient] First result: #{results.first.inspect[0..500]}"
      end

      results.filter_map { |result| parse_search_result(result) }
    end

    # Get book details by Hardcover book ID
    # Returns BookDetails
    def book(book_id)
      ensure_configured!

      query_string = <<~GRAPHQL
        query GetBook($id: Int!) {
          books(where: { id: { _eq: $id } }) {
            id
            title
            description
            release_year
            cached_image
            contributions {
              author {
                name
              }
            }
            default_physical_edition {
              pages
            }
            book_series {
              position
              series {
                id
                name
              }
            }
            featured_book_series {
              position
              series {
                id
                name
              }
            }
          }
        }
      GRAPHQL

      response = execute_query(query_string, { id: book_id.to_i })
      books = response.dig("data", "books") || []

      raise NotFoundError, "Book not found: #{book_id}" if books.empty?

      parse_book_details(books.first)
    end

    def series_books(series_id, limit: nil)
      ensure_configured!

      limit_clause = limit.present? ? ", limit: $limit" : ""
      query_string = <<~GRAPHQL
        query GetSeriesBooks($id: Int!#{", $limit: Int!" if limit.present?}) {
          series(where: { id: { _eq: $id } }, limit: 1) {
            id
            name
            book_series(order_by: { position: asc }#{limit_clause}) {
              position
              book {
                id
                title
                description
                release_year
                cached_image
                contributions {
                  author {
                    name
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      variables = { id: series_id.to_i }
      variables[:limit] = limit.to_i if limit.present?
      response = execute_query(query_string, variables)
      series = Array(response.dig("data", "series")).first
      return [] unless series

      Array(series["book_series"]).filter_map do |entry|
        book = entry["book"]
        next unless book.is_a?(Hash)

        SearchResult.new(
          id: book["id"]&.to_s,
          title: book["title"],
          author: extract_author(book),
          description: book["description"],
          release_year: book["release_year"],
          cover_url: extract_cover_url(book),
          has_audiobook: false,
          has_ebook: false,
          series_name: series["name"],
          series_position: normalize_series_position(entry["position"])
        )
      end
    end

    # Test API connection
    def test_connection
      ensure_configured!

      # Simple query to verify authentication
      query_string = <<~GRAPHQL
        query TestConnection {
          me {
            id
          }
        }
      GRAPHQL

      response = execute_query(query_string, {})

      # Check if we got a valid response with data
      # API returns me as an array: {"data"=>{"me"=>[{"id"=>69591}]}}
      data = response["data"] if response.is_a?(Hash)
      me = data["me"] if data.is_a?(Hash)
      me = me.first if me.is_a?(Array)
      result = me.is_a?(Hash) && me["id"].present?

      Rails.logger.info "[HardcoverClient] Connection test: #{result ? 'passed' : 'failed'}"
      result
    rescue RateLimitError
      raise
    rescue Error => e
      Rails.logger.error "[HardcoverClient] Connection test failed: #{e.message}"
      false
    end

    def reset_connection!
      REQUEST_MUTEX.synchronize do
        @connection = nil
        @connection_credential_digest = nil
      end
    end

    def rate_limited?
      active_rate_limit_retry_after(current_credential.digest).present?
    end

    # Test/maintenance hook. Normal request paths must retain the
    # server-advertised cooldown instead of bypassing it.
    def reset_rate_limit_state!
      credential_digest = current_credential.digest
      cache_keys = RATE_LIMIT_BUCKETS.map { |bucket| rate_limit_cache_key(bucket, credential_digest) }
      RATE_LIMIT_STATE_MUTEX.synchronize { @local_rate_limit_deadlines = {} }
      cache_keys.each { |key| safe_cache_delete(key) }
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "Hardcover API token not configured" unless configured?
    end

    def execute_query(query, variables)
      credential = current_credential
      with_rate_limit_request_lock(credential.digest) do
        ensure_not_rate_limited!(credential.digest)

        response = Timeout.timeout(
          HARD_REQUEST_TIMEOUT,
          ConnectionError,
          "Hardcover request timed out"
        ) do
          connection(credential).post do |req|
            req.body = { query: query, variables: variables }.to_json
          end
        end

        handle_response(response, credential.digest)
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      Rails.logger.error "[HardcoverClient] Connection error: #{e.message}"
      raise ConnectionError, "Failed to connect to Hardcover: #{e.message}"
    end

    def connection(credential = current_credential)
      return @connection if @connection && @connection_credential_digest == credential.digest

      @connection = Faraday.new(url: BASE_URL) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/json"
        f.headers["Authorization"] = credential.authorization_header
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
      @connection_credential_digest = credential.digest
      @connection
    end

    def api_token
      SettingsService.get(:hardcover_api_token)
    end

    def current_credential
      token = api_token.to_s.strip.sub(/\ABearer\s+/i, "").strip
      Credential.new(
        authorization_header: "Bearer #{token}",
        digest: Digest::SHA256.hexdigest(token)
      )
    end

    def handle_response(response, credential_digest)
      if response.status == 429
        handle_rate_limit_response!(response, credential_digest)
      else
        observe_rate_limit_headers(response.headers, credential_digest)
      end

      case response.status
      when 200
        body = response.body
        if body["errors"]&.any?
          error_message = body["errors"].map { |e| e["message"] }.join(", ")
          Rails.logger.error "[HardcoverClient] GraphQL error: #{error_message}"
          raise Error, "GraphQL error: #{error_message}"
        end
        body
      when 401, 403
        Rails.logger.error "[HardcoverClient] Authentication failed (status #{response.status})"
        raise AuthenticationError, "Invalid API token"
      else
        Rails.logger.error "[HardcoverClient] API error (status #{response.status})"
        raise Error, "API request failed with status #{response.status}"
      end
    end

    def handle_rate_limit_response!(response, credential_digest)
      retry_after = retry_after_seconds(response_header(response.headers, "Retry-After"), fallback: nil)

      if retry_after
        # Retry-After is authoritative for a 429. Discard older bucket hints so
        # a stale RateLimit value cannot silently extend or shorten it.
        clear_rate_limit_buckets!(credential_digest)
        remember_rate_limit!(:retry, retry_after, credential_digest)
      else
        observe_rate_limit_headers(response.headers, credential_digest)
        retry_after = active_rate_limit_retry_after(credential_digest) || DEFAULT_RATE_LIMIT_COOLDOWN
        remember_rate_limit!(:retry, retry_after, credential_digest) unless active_rate_limit_retry_after(credential_digest)
      end

      effective_retry_after = active_rate_limit_retry_after(credential_digest) || retry_after
      Rails.logger.warn "[HardcoverClient] Rate limited; retry in #{effective_retry_after} seconds"
      raise RateLimitError.new(
        "Hardcover rate limit exceeded; retry in #{effective_retry_after} seconds",
        retry_after: effective_retry_after
      )
    end

    def ensure_not_rate_limited!(credential_digest)
      retry_after = active_rate_limit_retry_after(credential_digest)
      return unless retry_after

      raise RateLimitError.new(
        "Hardcover rate limit cooldown active; retry in #{retry_after} seconds",
        retry_after: retry_after
      )
    end

    def observe_rate_limit_headers(headers, credential_digest)
      states = parse_rate_limit_entries(response_header(headers, "RateLimit"))
      policies = parse_rate_limit_entries(response_header(headers, "RateLimit-Policy"))
      usable_states = states.select { |entry| integer_parameter(entry, "r") }

      if usable_states.any?
        usable_states.each do |state|
          next unless integer_parameter(state, "r") <= 0

          policy = matching_rate_limit_policy(state, policies)
          bucket = rate_limit_bucket(state, policy)
          reset_after = cooldown_seconds(integer_parameter(state, "t"), fallback: DEFAULT_RATE_LIMIT_COOLDOWN)
          remember_rate_limit!(bucket, reset_after, credential_digest)
        end
        return
      end

      observe_legacy_rate_limit_headers(headers, credential_digest)
    end

    def observe_legacy_rate_limit_headers(headers, credential_digest)
      daily_remaining = header_integer(headers, "X-RateLimit-Daily-Remaining")
      if daily_remaining && daily_remaining <= 0
        reset_after = seconds_until_epoch(header_integer(headers, "X-RateLimit-Daily-Reset"))
        remember_rate_limit!(:daily, reset_after || DEFAULT_RATE_LIMIT_COOLDOWN, credential_digest)
      end

      remaining = header_integer(headers, "X-RateLimit-Remaining")
      return unless remaining && remaining <= 0

      reset_after = seconds_until_epoch(header_integer(headers, "X-RateLimit-Reset"))
      remember_rate_limit!(:minute, reset_after || DEFAULT_RATE_LIMIT_COOLDOWN, credential_digest)
    end

    def parse_rate_limit_entries(value)
      split_rate_limit_entries(value).filter_map do |raw_entry|
        identifier, *raw_parameters = raw_entry.split(";")
        identifier = identifier.to_s.strip
        identifier = identifier.delete_prefix(%(")).delete_suffix(%(")).strip
        next if identifier.blank?

        parameters = raw_parameters.each_with_object({}) do |raw_parameter, parsed|
          key, raw_value = raw_parameter.split("=", 2)
          next if raw_value.nil?

          parsed[key.to_s.strip.downcase] = raw_value.to_s.strip.delete_prefix(%(")).delete_suffix(%(")).strip
        end
        { identifier: identifier, parameters: parameters }
      end
    end

    def split_rate_limit_entries(value)
      input = value.to_s.byteslice(0, MAX_RATE_LIMIT_HEADER_BYTES).to_s
      entries = []
      current = +""
      quoted = false
      escaped = false

      input.each_char do |character|
        if character == "," && !quoted
          entries << current.strip
          current = +""
          next
        end

        current << character
        if character == "\\" && quoted
          escaped = !escaped
        elsif character == '"' && !escaped
          quoted = !quoted
        else
          escaped = false
        end
      end
      entries << current.strip unless current.blank?
      entries
    end

    def matching_rate_limit_policy(state, policies)
      policies.find do |policy|
        policy[:identifier].casecmp?(state[:identifier])
      end
    end

    def rate_limit_bucket(state, policy)
      window = integer_parameter(policy, "w")
      return :daily if state[:identifier].casecmp?("daily")
      return :daily if window && window >= 1.hour.to_i

      :minute
    end

    def integer_parameter(entry, name)
      return unless entry

      bounded_integer(entry[:parameters][name])
    end

    def header_integer(headers, name)
      bounded_integer(response_header(headers, name))
    end

    def bounded_integer(value)
      raw_value = value.to_s.byteslice(0, 64).to_s.strip
      Integer(raw_value, exception: false)
    end

    def retry_after_seconds(value, fallback: DEFAULT_RATE_LIMIT_COOLDOWN)
      raw_value = value.to_s.byteslice(0, 128).to_s.strip
      seconds = bounded_integer(raw_value)
      seconds ||= (Time.httpdate(raw_value) - Time.current).ceil if raw_value.present?
      cooldown_seconds(seconds, fallback: fallback)
    rescue ArgumentError
      cooldown_seconds(nil, fallback: fallback)
    end

    def cooldown_seconds(seconds, fallback:)
      seconds = fallback unless seconds&.positive?
      return unless seconds

      seconds.clamp(MIN_RATE_LIMIT_COOLDOWN, MAX_RATE_LIMIT_COOLDOWN)
    end

    def seconds_until_epoch(epoch)
      return unless epoch

      cooldown_seconds(epoch - Time.current.to_i, fallback: nil)
    end

    def response_header(headers, name)
      value = headers[name]
      value = value.join(", ") if value.is_a?(Array)
      value
    end

    # Solid Cache makes this lease shared across Puma and job processes. The
    # mutex preserves the same safety under NullStore and during cache outages.
    def with_rate_limit_request_lock(credential_digest)
      REQUEST_MUTEX.synchronize do
        token = SecureRandom.hex(16)
        deadline = monotonic_time + REQUEST_LOCK_WAIT

        loop do
          lease_started_at = monotonic_time
          if acquire_request_lock(token, credential_digest)
            begin
              return yield
            ensure
              release_request_lock(token, credential_digest, acquired_at: lease_started_at)
            end
          end

          if monotonic_time >= deadline
            raise ConnectionError, "Hardcover API is busy; try again shortly"
          end

          sleep REQUEST_LOCK_POLL_INTERVAL
        end
      end
    end

    def acquire_request_lock(token, credential_digest)
      key = request_lock_cache_key(credential_digest)
      written = Rails.cache.write(
        key,
        token,
        expires_in: REQUEST_LOCK_TTL,
        unless_exist: true
      )
      return true if written
      return false if Rails.cache.read(key).present?

      !cache_operational?(credential_digest)
    rescue StandardError
      true
    end

    def release_request_lock(token, credential_digest, acquired_at:)
      # Never let an owner whose lease already expired inspect or delete a
      # successor's entry. The hard request timeout keeps normal requests well
      # inside this boundary.
      return false if monotonic_time - acquired_at >= REQUEST_LOCK_TTL

      key = request_lock_cache_key(credential_digest)
      Rails.cache.delete(key) if Rails.cache.read(key) == token
    rescue StandardError
      false
    end

    def cache_operational?(credential_digest)
      token = SecureRandom.hex(16)
      key = "#{request_lock_cache_key(credential_digest)}:probe:#{token}"
      written = Rails.cache.write(key, token, expires_in: 5.seconds)
      written && Rails.cache.read(key) == token
    ensure
      Rails.cache.delete(key) if key
    end

    def active_rate_limit_retry_after(credential_digest)
      retry_after = active_bucket_retry_after(:retry, credential_digest)
      return retry_after if retry_after

      RATE_LIMIT_BUCKETS.excluding(:retry).filter_map do |bucket|
        active_bucket_retry_after(bucket, credential_digest)
      end.max
    end

    def active_bucket_retry_after(bucket, credential_digest)
      key = rate_limit_cache_key(bucket, credential_digest)
      local_remaining = local_rate_limit_remaining(key)
      cached_deadline = safe_cache_read(key)
      cached_remaining = cached_deadline - Time.current.to_f if cached_deadline
      remaining = [ local_remaining, cached_remaining ].compact.select(&:positive?).max
      cooldown_seconds(remaining&.ceil, fallback: nil)
    end

    def local_rate_limit_remaining(key)
      RATE_LIMIT_STATE_MUTEX.synchronize do
        deadline = local_rate_limit_deadlines[key]
        next unless deadline

        remaining = deadline - monotonic_time
        local_rate_limit_deadlines.delete(key) unless remaining.positive?
        remaining if remaining.positive?
      end
    end

    def remember_rate_limit!(bucket, seconds, credential_digest)
      seconds = cooldown_seconds(seconds, fallback: DEFAULT_RATE_LIMIT_COOLDOWN)
      key = rate_limit_cache_key(bucket, credential_digest)

      RATE_LIMIT_STATE_MUTEX.synchronize do
        deadline = monotonic_time + seconds
        existing = local_rate_limit_deadlines[key]
        local_rate_limit_deadlines[key] = [ existing, deadline ].compact.max
      end

      wall_deadline = Time.current.to_f + seconds
      existing_deadline = safe_cache_read(key)
      wall_deadline = [ existing_deadline, wall_deadline ].compact.max
      safe_cache_write(key, wall_deadline, expires_in: (wall_deadline - Time.current.to_f).ceil)
    end

    def clear_rate_limit_buckets!(credential_digest)
      keys = RATE_LIMIT_BUCKETS.map { |bucket| rate_limit_cache_key(bucket, credential_digest) }
      RATE_LIMIT_STATE_MUTEX.synchronize do
        keys.each { |key| local_rate_limit_deadlines.delete(key) }
      end
      keys.each { |key| safe_cache_delete(key) }
    end

    def local_rate_limit_deadlines
      @local_rate_limit_deadlines ||= {}
    end

    def rate_limit_cache_key(bucket, credential_digest)
      "hardcover:v#{RATE_LIMIT_CACHE_VERSION}:rate-limit:#{credential_digest}:#{bucket}"
    end

    def request_lock_cache_key(credential_digest)
      "hardcover:v#{RATE_LIMIT_CACHE_VERSION}:request-lock:#{credential_digest}"
    end

    def safe_cache_read(key)
      value = Float(Rails.cache.read(key), exception: false)
      value if value&.finite?
    rescue StandardError
      nil
    end

    def safe_cache_write(key, value, expires_in:)
      Rails.cache.write(key, value, expires_in: expires_in)
    rescue StandardError
      false
    end

    def safe_cache_delete(key)
      Rails.cache.delete(key)
    rescue StandardError
      false
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def parse_search_result(result)
      doc = result["document"]
      return nil unless doc.is_a?(Hash)

      SearchResult.new(
        id: doc["id"]&.to_s,
        title: doc["title"],
        author: extract_author(doc),
        description: doc["description"],
        release_year: doc["release_year"],
        cover_url: extract_cover_url(doc),
        has_audiobook: doc["has_audiobook"] || false,
        has_ebook: doc["has_ebook"] || false,
        series_name: nil,
        series_position: nil
      )
    end

    def extract_author(doc)
      doc["author_names"]&.first || doc.dig("contributions", 0, "author", "name") || doc["author"]
    end

    def parse_book_details(book)
      # Extract author from contributions
      author = book.dig("contributions", 0, "author", "name")

      series = featured_or_first_series(book)

      # Extract pages from default edition
      pages = book.dig("default_physical_edition", "pages")

      BookDetails.new(
        id: book["id"].to_s,
        title: book["title"],
        author: author,
        description: book["description"],
        release_year: book["release_year"],
        cover_url: extract_cover_url(book),
        has_audiobook: false, # Not available in this query
        has_ebook: false,     # Not available in this query
        pages: pages,
        genres: [],           # Would need separate query
        series_id: series&.dig("series", "id")&.to_s,
        series_name: series&.dig("series", "name"),
        series_position: normalize_series_position(series&.[]("position"))
      )
    end

    def extract_cover_url(doc)
      cached = doc["cached_image"]
      image = doc["image"]

      cached_url = cached.is_a?(Hash) ? cached["url"] : cached
      image_url = image.is_a?(Hash) ? image["url"] : image

      cached_url || image_url
    end

    def extract_hits(raw_results)
      return [] unless raw_results.is_a?(Hash)

      hits = raw_results["hits"]
      hits.is_a?(Array) ? hits : []
    end

    def featured_or_first_series(book)
      featured = book["featured_book_series"]
      return featured if featured.is_a?(Hash)
      return featured.first if featured.is_a?(Array) && featured.any?

      series = book["book_series"]
      series.is_a?(Array) ? series.first : nil
    end

    def normalize_series_position(value)
      return nil if value.blank?
      return value.to_i.to_s if value.is_a?(Numeric) && value.to_i == value

      value.to_s
    end
  end
end
