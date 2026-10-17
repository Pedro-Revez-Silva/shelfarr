# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "timeout"

class HardcoverClient
  BASE_URL = "https://api.hardcover.app/v1/graphql"
  RATE_LIMIT_CACHE_VERSION = 1
  RATE_LIMIT_BUCKETS = %i[retry minute daily].freeze
  DEFAULT_RATE_LIMIT_COOLDOWN = 60
  MIN_RATE_LIMIT_COOLDOWN = 1
  MAX_RATE_LIMIT_COOLDOWN = 25.hours.to_i
  MAX_RATE_LIMIT_HEADER_BYTES = 4.kilobytes
  RATE_LIMIT_STATE_MUTEX = Mutex.new
  REQUEST_MUTEXES_MUTEX = Mutex.new
  CONNECTIONS_MUTEX = Mutex.new
  MAX_CACHED_CONNECTIONS = 32
  HARD_REQUEST_TIMEOUT = 35.seconds
  REQUEST_LOCK_TTL = HARD_REQUEST_TIMEOUT + 10.seconds
  REQUEST_LOCK_WAIT = REQUEST_LOCK_TTL + 1.second
  REQUEST_LOCK_POLL_INTERVAL = 0.05
  # Background work spends at most the per-minute refill rate and leaves part
  # of the daily allowance for people browsing Shelfarr. Every background
  # caller reserves its own send slot for the account, so concurrent jobs
  # queue behind each other instead of waking up and sending together.
  BACKGROUND_MIN_INTERVAL = 1.1
  BACKGROUND_MAX_PACING_SLEEP = 3.0
  BACKGROUND_MAX_QUEUE_WAIT = 30.0
  BACKGROUND_DAILY_RESERVE_RATIO = 0.1
  MIN_BACKGROUND_DAILY_RESERVE = 100
  ACCOUNT_CACHE_TTL = 30.days

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
  # The token is valid but lacks a scope the query needs.
  class ScopeError < AuthenticationError
    attr_reader :scope

    def initialize(message, scope: nil)
      @scope = scope
      super(message)
    end
  end
  # More top-level fields than the account's burst size. Retrying cannot help.
  class QueryTooLargeError < Error; end
  class TransientError < ConnectionError; end

  # `digest` identifies the shared rate budget. Hardcover limits each account
  # across all of its tokens and apps, so account-backed credentials share a
  # digest even when the token itself changes.
  Credential = Data.define(:authorization_header, :digest)

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

      # Hardcover returns `me` as an array: {"data"=>{"me"=>[{"id"=>69591}]}}
      data = response["data"] if response.is_a?(Hash)
      me = data["me"] if data.is_a?(Hash)
      me = me.first if me.is_a?(Array)
      result = me.is_a?(Hash) && me["id"].present?
      remember_instance_account!(me["id"]) if result

      Rails.logger.info "[HardcoverClient] Connection test: #{result ? 'passed' : 'failed'}"
      result
    rescue RateLimitError
      raise
    rescue Error => e
      Rails.logger.error "[HardcoverClient] Connection test failed: #{e.message}"
      false
    end

    # Runs a query with an explicit credential. Used by per-user connections
    # and by the discovery/subscription features. `background: true` paces the
    # request and keeps a daily reserve for interactive use.
    def execute(query, variables = {}, credential:, background: false)
      execute_query(query, variables, credential: credential, background: background)
    end

    def instance_credential
      ensure_configured!
      current_credential
    end

    def credential_for_token(token, budget_key: nil)
      normalized = normalize_token(token)
      Credential.new(
        authorization_header: "Bearer #{normalized}",
        digest: Digest::SHA256.hexdigest(budget_key.presence || "token:#{normalized}")
      )
    end

    def account_budget_key(hardcover_user_id)
      "account:#{Integer(hardcover_user_id)}"
    end

    # Remembers which Hardcover account owns the instance token so the token
    # and that person's own connection draw from one budget.
    def remember_instance_account!(hardcover_user_id)
      token_digest = Digest::SHA256.hexdigest(normalize_token(api_token))
      safe_cache_write(instance_account_cache_key(token_digest), Integer(hardcover_user_id), expires_in: ACCOUNT_CACHE_TTL)
    rescue ArgumentError, TypeError
      false
    end

    def reset_connection!
      CONNECTIONS_MUTEX.synchronize { @connections = {} }
    end

    def rate_limited?
      active_rate_limit_retry_after(current_credential.digest).present?
    end

    # Test/maintenance hook. Normal request paths must retain the server-advertised cooldown instead of bypassing it.
    def reset_rate_limit_state!
      credential_digest = current_credential.digest
      cache_keys = RATE_LIMIT_BUCKETS.map { |bucket| rate_limit_cache_key(bucket, credential_digest) }
      cache_keys += %i[slot sent].map { |kind| pacing_cache_key(kind, credential_digest) }
      RATE_LIMIT_STATE_MUTEX.synchronize do
        @local_rate_limit_deadlines = {}
        @local_pacing = {}
      end
      cache_keys.each { |key| safe_cache_delete(key) }
    end

    # Seconds between background sends for one Hardcover account. The test
    # environment lowers it so suites do not sleep between stubbed pages.
    def background_min_interval
      HardcoverIntegration.configured_seconds(:hardcover_background_min_interval, BACKGROUND_MIN_INTERVAL)
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "Hardcover API token not configured" unless configured?
    end

    def execute_query(query, variables, credential: current_credential, background: false)
      reserve_background_slot!(credential.digest) if background

      with_rate_limit_request_lock(credential.digest) do
        ensure_not_rate_limited!(credential.digest)
        if background
          # Another request may have used the daily allowance down to the
          # interactive reserve while this one waited for its slot.
          ensure_background_budget!(credential.digest)
          space_background_send!(credential.digest)
        end

        begin
          response = Timeout.timeout(
            HARD_REQUEST_TIMEOUT,
            ConnectionError,
            "Hardcover request timed out"
          ) do
            connection(credential).post do |req|
              req.body = { query: query, variables: variables }.to_json
            end
          end
        ensure
          # The request reaches Hardcover somewhere between dispatch and the
          # end of the attempt, and preparing it can be delayed (GC, a busy
          # process). Stamping once the attempt is over, still under the
          # lease, keeps the next send a full interval behind it either way,
          # including when the attempt failed after leaving the process.
          remember_send!(credential.digest)
        end

        handle_response(response, credential.digest)
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      Rails.logger.error "[HardcoverClient] Connection error: #{e.message}"
      raise ConnectionError, "Failed to connect to Hardcover: #{e.message}"
    end

    # Connections are cached per exact Authorization header. Several tokens
    # can share one account budget, and requests for different accounts run
    # concurrently, so a shared single connection could send the wrong token.
    def connection(credential = current_credential)
      key = Digest::SHA256.hexdigest(credential.authorization_header)
      CONNECTIONS_MUTEX.synchronize do
        @connections ||= {}
        existing = @connections.delete(key)
        @connections.shift while @connections.size >= MAX_CACHED_CONNECTIONS
        @connections[key] = existing || build_connection(credential)
      end
    end

    def build_connection(credential)
      Faraday.new(url: BASE_URL) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/json"
        f.headers["Authorization"] = credential.authorization_header
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def api_token
      SettingsService.get(:hardcover_api_token)
    end

    def current_credential
      token = normalize_token(api_token)
      token_digest = Digest::SHA256.hexdigest(token)
      account_id = Integer(safe_cache_read_raw(instance_account_cache_key(token_digest)), exception: false)
      digest = account_id ? Digest::SHA256.hexdigest(account_budget_key(account_id)) : token_digest
      Credential.new(authorization_header: "Bearer #{token}", digest: digest)
    end

    def normalize_token(token)
      token.to_s.strip.sub(/\ABearer\s+/i, "").strip
    end

    def instance_account_cache_key(token_digest)
      "hardcover:v#{RATE_LIMIT_CACHE_VERSION}:instance-account:#{token_digest}"
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
        raise Error, "Hardcover returned an unexpected response" unless body.is_a?(Hash)

        if body["errors"].present?
          error_message = graphql_error_messages(body["errors"])
          Rails.logger.error "[HardcoverClient] GraphQL error: #{error_message}"
          raise Error, "GraphQL error: #{error_message}"
        end
        body
      when 401
        Rails.logger.error "[HardcoverClient] Authentication failed (status 401)"
        raise AuthenticationError, "Invalid API token"
      when 403
        raise_forbidden!(response.body)
      when 408, 500, 502, 503, 504
        Rails.logger.error "[HardcoverClient] Temporary API error (status #{response.status})"
        raise TransientError, "Hardcover is temporarily unavailable (status #{response.status})"
      else
        Rails.logger.error "[HardcoverClient] API error (status #{response.status})"
        raise Error, "API request failed with status #{response.status}"
      end
    end

    def raise_forbidden!(body)
      body = body.is_a?(Hash) ? body : {}
      errors = Array(body["errors"]).map { |error| error.is_a?(Hash) ? error["message"].to_s : error.to_s }

      if errors.include?("request_exceeds_capacity") || body["error"] == "request_exceeds_capacity"
        Rails.logger.error "[HardcoverClient] Query has more top-level fields than the burst limit"
        raise QueryTooLargeError, "Hardcover rejected the query because it requests too many fields at once"
      end

      if body["error"] == "insufficient_scope"
        scope = body["scope"].to_s.byteslice(0, 200)
        Rails.logger.error "[HardcoverClient] Token is missing scope #{scope.presence || '(unspecified)'}"
        raise ScopeError.new("Hardcover token is missing the #{scope.presence || 'required'} permission", scope: scope.presence)
      end

      Rails.logger.error "[HardcoverClient] Authentication failed (status 403)"
      raise AuthenticationError, "Invalid API token"
    end

    def graphql_error_messages(errors)
      Array(errors).map { |error| error.is_a?(Hash) ? error["message"] : error }.compact.join(", ").byteslice(0, 500)
    end

    def ensure_background_budget!(credential_digest)
      state = safe_cache_read_raw(remaining_cache_key(:daily, credential_digest))
      return unless state.is_a?(Hash)

      remaining = Integer(state["r"], exception: false)
      limit = Integer(state["q"], exception: false)
      reset_at = Float(state["reset_at"], exception: false)
      return unless remaining && reset_at && reset_at > Time.current.to_f

      reserve = [ ((limit || 0) * BACKGROUND_DAILY_RESERVE_RATIO).ceil, MIN_BACKGROUND_DAILY_RESERVE ].max
      return if remaining > reserve

      retry_after = cooldown_seconds((reset_at - Time.current.to_f).ceil, fallback: DEFAULT_RATE_LIMIT_COOLDOWN)
      raise RateLimitError.new(
        "Hardcover daily allowance is reserved for interactive use; background sync resumes in #{retry_after} seconds",
        retry_after: retry_after
      )
    end

    # Admission and pacing for background work happen under the account's
    # request lease: the daily reserve and any cooldown are checked (and
    # checked again when the slot comes up), and the
    # caller is given the next free send slot. Slots are handed out in order,
    # so concurrent jobs on one account are spaced out instead of sleeping
    # against the same timestamp and sending together.
    def reserve_background_slot!(credential_digest)
      slot = with_rate_limit_request_lock(credential_digest) do
        ensure_background_budget!(credential_digest)
        now = Time.current.to_f
        reserved = [ now, next_background_slot(credential_digest) ].compact.max

        cooldown = active_rate_limit_retry_after(credential_digest)
        if cooldown
          # A short cooldown (an exhausted burst bucket) is waited out; a long one is reported so the job backs off.
          ensure_not_rate_limited!(credential_digest) if cooldown > BACKGROUND_MAX_PACING_SLEEP
          reserved = [ reserved, now + cooldown ].max
        end

        wait = reserved - now
        if wait > BACKGROUND_MAX_QUEUE_WAIT
          raise RateLimitError.new(
            "Hardcover background requests for this account are queued; retrying in #{wait.ceil} seconds",
            retry_after: wait.ceil
          )
        end

        remember_next_background_slot!(credential_digest, reserved + background_min_interval)
        reserved
      end

      wait = slot - Time.current.to_f
      sleep(wait) if wait.positive?
    end

    # Runs inside the lease right before sending. Slots are already spaced;
    # this keeps a full interval after the previous attempt ended, which also
    # covers a slot delayed by an interactive or slow request.
    def space_background_send!(credential_digest)
      last = last_send_at(credential_digest)
      return unless last

      wait = [ last + background_min_interval - Time.current.to_f, background_min_interval ].min
      sleep(wait) if wait.positive?
    end

    # A slot can legitimately be at most one queue's length ahead. Anything
    # later comes from a wall-clock jump and is ignored, so it cannot stall
    # the account.
    def next_background_slot(credential_digest)
      pacing_value(:slot, credential_digest, ceiling: Time.current.to_f + BACKGROUND_MAX_QUEUE_WAIT + background_min_interval)
    end

    def remember_next_background_slot!(credential_digest, value)
      remember_pacing_value!(:slot, credential_digest, value)
    end

    def last_send_at(credential_digest)
      pacing_value(:sent, credential_digest, ceiling: Time.current.to_f)
    end

    def remember_send!(credential_digest)
      remember_pacing_value!(:sent, credential_digest, Time.current.to_f)
    end

    # The shared cache spans processes; the in-process copy keeps pacing
    # working under NullStore or during a cache outage. Values past
    # `ceiling` are ignored.
    def pacing_value(kind, credential_digest, ceiling:)
      key = pacing_cache_key(kind, credential_digest)
      local = RATE_LIMIT_STATE_MUTEX.synchronize { local_pacing[key] }
      [ local, safe_cache_read(key) ].compact.select { |value| value <= ceiling }.max
    end

    # Written under the account's request lease, so the newest value is always the one to keep.
    def remember_pacing_value!(kind, credential_digest, value)
      key = pacing_cache_key(kind, credential_digest)
      RATE_LIMIT_STATE_MUTEX.synchronize { local_pacing[key] = value }
      ttl = [ (value - Time.current.to_f).ceil, 0 ].max + 1.minute.to_i
      safe_cache_write(key, value, expires_in: ttl)
    end

    def pacing_cache_key(kind, credential_digest)
      "hardcover:v#{RATE_LIMIT_CACHE_VERSION}:background-pace:#{kind}:#{credential_digest}"
    end

    def local_pacing
      @local_pacing ||= {}
    end

    def remember_remaining!(bucket, remaining:, quota:, reset_after:, credential_digest:)
      return unless remaining && reset_after&.positive?

      state = { "r" => remaining, "q" => quota, "reset_at" => Time.current.to_f + reset_after }
      safe_cache_write(remaining_cache_key(bucket, credential_digest), state, expires_in: reset_after.ceil)
    end

    def remaining_cache_key(bucket, credential_digest)
      "hardcover:v#{RATE_LIMIT_CACHE_VERSION}:remaining:#{credential_digest}:#{bucket}"
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
          policy = matching_rate_limit_policy(state, policies)
          if rate_limit_bucket(state, policy) == :daily
            remember_remaining!(
              :daily,
              remaining: integer_parameter(state, "r"),
              quota: integer_parameter(policy, "q"),
              reset_after: integer_parameter(state, "t"),
              credential_digest: credential_digest
            )
          end
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
      remember_remaining!(
        :daily,
        remaining: daily_remaining,
        quota: header_integer(headers, "X-RateLimit-Daily-Limit"),
        reset_after: seconds_until_epoch(header_integer(headers, "X-RateLimit-Daily-Reset")),
        credential_digest: credential_digest
      )
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
    # per-account mutex preserves the same safety under NullStore and during
    # cache outages without making unrelated accounts wait for each other.
    def with_rate_limit_request_lock(credential_digest)
      request_mutex(credential_digest).synchronize do
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

    def request_mutex(credential_digest)
      REQUEST_MUTEXES_MUTEX.synchronize do
        @request_mutexes ||= {}
        @request_mutexes[credential_digest] ||= Mutex.new
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

    def safe_cache_read_raw(key)
      Rails.cache.read(key)
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
      author = book.dig("contributions", 0, "author", "name")

      series = featured_or_first_series(book)

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
