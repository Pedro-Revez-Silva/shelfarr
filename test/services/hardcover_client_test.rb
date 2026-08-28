# frozen_string_literal: true

require "test_helper"

class HardcoverClientTest < ActiveSupport::TestCase
  setup do
    @original_token = SettingsService.get(:hardcover_api_token)
    @original_enabled = SettingsService.get(:hardcover_enabled, default: true)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    SettingsService.set(:hardcover_enabled, true)
    HardcoverClient.reset_connection!
    HardcoverClient.reset_rate_limit_state!
  end

  teardown do
    HardcoverClient.reset_rate_limit_state!
    SettingsService.set(:hardcover_api_token, @original_token || "")
    SettingsService.set(:hardcover_enabled, @original_enabled)
    HardcoverClient.reset_connection!
    Rails.cache = @original_cache
  end

  test "configured? returns false without token" do
    SettingsService.set(:hardcover_api_token, "")
    assert_not HardcoverClient.configured?
  end

  test "configured? returns true with token" do
    SettingsService.set(:hardcover_api_token, "test_token")
    assert HardcoverClient.configured?
  end

  test "configured? returns false when Hardcover is disabled despite a saved token" do
    SettingsService.set(:hardcover_api_token, "test_token")
    SettingsService.set(:hardcover_enabled, false)

    assert_not HardcoverClient.configured?
  end

  test "search raises NotConfiguredError without token" do
    SettingsService.set(:hardcover_api_token, "")

    assert_raises HardcoverClient::NotConfiguredError do
      HardcoverClient.search("test")
    end
  end

  test "search returns array of SearchResult" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("lord of the rings", [
        { "id" => 123, "title" => "The Lord of the Rings", "author_names" => [ "J.R.R. Tolkien" ],
          "release_year" => 1954, "cached_image" => "https://example.com/cover.jpg",
          "has_audiobook" => true, "has_ebook" => true }
      ])

      results = HardcoverClient.search("lord of the rings")

      assert_kind_of Array, results
      assert_equal 1, results.size
      assert_kind_of HardcoverClient::SearchResult, results.first

      result = results.first
      assert_equal "The Lord of the Rings", result.title
      assert_equal "J.R.R. Tolkien", result.author
      assert_equal 1954, result.release_year
      assert result.has_audiobook
      assert result.has_ebook
    end
  end

  test "search handles empty results" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("asdfghjklqwertyuiop", [])

      results = HardcoverClient.search("asdfghjklqwertyuiop")
      assert_equal [], results
    end
  end

  test "search returns empty array when results shape is invalid" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "search" => { "results" => [] } } }.to_json
        )

      results = HardcoverClient.search("lord of the rings")

      assert_equal [], results
    end
  end

  test "search extracts cover_url from image hash" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("dune", [
        {
          "id" => 123,
          "title" => "Dune",
          "author_names" => [ "Frank Herbert" ],
          "release_year" => 1965,
          "cached_image" => nil,
          "image" => { "url" => "https://example.com/image-cover.jpg" },
          "has_audiobook" => true,
          "has_ebook" => true
        }
      ])

      results = HardcoverClient.search("dune")

      assert_equal 1, results.size
      assert_equal "https://example.com/image-cover.jpg", results.first.cover_url
    end
  end

  test "book returns BookDetails" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(12345, {
        "id" => 12345,
        "title" => "Test Book",
        "description" => "A test description",
        "release_year" => 2020,
        "cached_image" => "https://example.com/cover.jpg",
        "contributions" => [ { "author" => { "name" => "Test Author" } } ],
        "default_physical_edition" => { "pages" => 300 },
        "book_series" => [ { "position" => 2, "series" => { "id" => 987, "name" => "Test Series" } } ]
      })

      book = HardcoverClient.book(12345)

      assert_kind_of HardcoverClient::BookDetails, book
      assert_equal "Test Book", book.title
      assert_equal "Test Author", book.author
      assert_equal 2020, book.release_year
      assert_equal 300, book.pages
      assert_equal "987", book.series_id
      assert_equal "Test Series", book.series_name
      assert_equal "2", book.series_position
    end
  end

  test "series_books returns books ordered within a series" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_series_books(987, "Test Series", [
        {
          "position" => 1,
          "book" => {
            "id" => 111,
            "title" => "Series Book One",
            "description" => "First book",
            "release_year" => 2020,
            "cached_image" => "https://example.com/one.jpg",
            "contributions" => [ { "author" => { "name" => "Series Author" } } ]
          }
        }
      ])

      books = HardcoverClient.series_books(987)

      assert_equal 1, books.size
      assert_equal "Series Book One", books.first.title
      assert_equal "Series Author", books.first.author
      assert_equal "Test Series", books.first.series_name
      assert_equal "1", books.first.series_position
    end
  end

  test "book extracts cover_url from cached_image hash" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(12346, {
        "id" => 12346,
        "title" => "Hash Cover Book",
        "description" => "A test description",
        "release_year" => 2021,
        "cached_image" => { "url" => "https://example.com/hash-cover.jpg" },
        "contributions" => [ { "author" => { "name" => "Test Author" } } ],
        "default_physical_edition" => { "pages" => 320 },
        "book_series" => []
      })

      book = HardcoverClient.book(12346)

      assert_equal "https://example.com/hash-cover.jpg", book.cover_url
    end
  end

  test "book raises NotFoundError for invalid id" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(999999999, nil)

      assert_raises HardcoverClient::NotFoundError do
        HardcoverClient.book(999999999)
      end
    end
  end

  test "handles authentication error" do
    SettingsService.set(:hardcover_api_token, "invalid_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 401, body: '{"error": "Unauthorized"}')

      assert_raises HardcoverClient::AuthenticationError do
        HardcoverClient.search("test")
      end
    end
  end

  test "handles rate limit error" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 429, body: '{"error": "Rate limit exceeded"}')

      assert_raises HardcoverClient::RateLimitError do
        HardcoverClient.search("test")
      end
    end
  end

  test "honors Retry-After and blocks another outbound request during the cooldown" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(
          status: 429,
          headers: { "Retry-After" => "120" },
          body: '{"error": "Rate limit exceeded"}'
        )

      first_error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end
      second_error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end

      assert_equal 120, first_error.retry_after
      assert_in_delta 120.seconds.from_now, first_error.retry_at, 1.second
      assert_match(/cooldown active/, second_error.message)
      assert_requested request_stub, times: 1
    end
  end

  test "Retry-After is authoritative over conflicting rate limit bucket headers" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(
          status: 429,
          headers: {
            "Retry-After" => "30",
            "RateLimit" => '"Free";r=0;t=60, "daily";r=0;t=80000',
            "RateLimit-Policy" => '"Free";q=60;w=60;burst=10, "daily";q=5000;w=86400'
          },
          body: '{"error": "Rate limit exceeded"}'
        )

      error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end

      assert_equal 30, error.retry_after
      assert_requested request_stub, times: 1
    end
  end

  test "successful response at zero remaining blocks the next request" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Free";r=0;t=42, "daily";r=4231;t=51234',
          "RateLimit-Policy" => '"Free";q=60;w=60;burst=10, "daily";q=5000;w=86400'
        }
      )

      assert_empty HardcoverClient.search("test")
      error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end

      assert_in_delta 42, error.retry_after, 1
      assert_requested request_stub, times: 1
    end
  end

  test "uses the longest exhausted server bucket without assuming a plan quota" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Custom";t=20;r=0, "daily";t=500;r=0',
          "RateLimit-Policy" => '"Custom";burst=25;w=60;q=250, "daily";w=86400;q=75000'
        }
      )

      assert_empty HardcoverClient.search("test")
      error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end

      assert_in_delta 500, error.retry_after, 1
      assert_requested request_stub, times: 1
    end
  end

  test "does not block a supporter or custom policy while the server reports capacity" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Supporter";r=58;t=20, "daily";r=49000;t=500',
          "RateLimit-Policy" => '"Supporter";q=60;w=60;burst=15, "daily";q=50000;w=86400'
        }
      )

      2.times { assert_empty HardcoverClient.search("test") }

      assert_requested request_stub, times: 2
    end
  end

  test "falls back to legacy exhaustion headers when modern headers are unusable" do
    SettingsService.set(:hardcover_api_token, "test_token")
    reset_at = 5.minutes.from_now.to_i

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Free";remaining=not-an-integer',
          "X-RateLimit-Daily-Remaining" => "0",
          "X-RateLimit-Daily-Reset" => reset_at.to_s
        }
      )

      assert_empty HardcoverClient.search("test")
      error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.search("test")
      end

      assert_in_delta 5.minutes.to_i, error.retry_after, 2
      assert_requested request_stub, times: 1
    end
  end

  test "valid modern headers take precedence over stale legacy exhaustion headers" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Free";r=8;t=42, "daily";r=4231;t=51234',
          "RateLimit-Policy" => '"Free";q=60;w=60;burst=10, "daily";q=5000;w=86400',
          "X-RateLimit-Daily-Remaining" => "0",
          "X-RateLimit-Daily-Reset" => 1.day.from_now.to_i.to_s
        }
      )

      2.times { assert_empty HardcoverClient.search("test") }

      assert_requested request_stub, times: 2
    end
  end

  test "rate limit cooldown is isolated by normalized API token" do
    SettingsService.set(:hardcover_api_token, "Bearer token-a")

    VCR.turned_off do
      first_token_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .with(headers: { "Authorization" => "Bearer token-a" })
        .to_return(status: 429, headers: { "Retry-After" => "120" }, body: "{}")
      second_token_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .with(headers: { "Authorization" => "Bearer token-b" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: empty_search_body
        )

      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }

      SettingsService.set(:hardcover_api_token, "token-b")
      assert_empty HardcoverClient.search("test")

      SettingsService.set(:hardcover_api_token, "token-a")
      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }

      assert_requested first_token_stub, times: 1
      assert_requested second_token_stub, times: 1
    end
  end

  test "resetting the HTTP connection does not bypass the cooldown" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 429, headers: { "Retry-After" => "120" }, body: "{}")

      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }
      HardcoverClient.reset_connection!
      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }

      assert_requested request_stub, times: 1
    end
  end

  test "concurrent callers observe exhaustion before a second request escapes" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      request_stub = stub_hardcover_response(
        headers: {
          "RateLimit" => '"Free";r=0;t=60',
          "RateLimit-Policy" => '"Free";q=60;w=60;burst=10'
        }
      )
      ready = Queue.new
      start = Queue.new

      workers = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          HardcoverClient.search("test")
        rescue StandardError => e
          e
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      outcomes = workers.map(&:value)

      assert_equal 1, outcomes.count { |outcome| outcome == [] }
      assert_equal 1, outcomes.count { |outcome| outcome.is_a?(HardcoverClient::RateLimitError) }
      assert_requested request_stub, times: 1
    end
  end

  test "rate limit parsing uses bounded fallbacks for malformed input" do
    assert_equal HardcoverClient::DEFAULT_RATE_LIMIT_COOLDOWN,
      HardcoverClient.send(:retry_after_seconds, "not-a-retry-date")
    assert_equal HardcoverClient::MAX_RATE_LIMIT_COOLDOWN,
      HardcoverClient.send(:retry_after_seconds, "9" * 10_000)

    http_date = 2.minutes.from_now.httpdate
    assert_in_delta 2.minutes.to_i, HardcoverClient.send(:retry_after_seconds, http_date), 1
  end

  test "local cooldown still protects requests when the cache store discards writes" do
    SettingsService.set(:hardcover_api_token, "test_token")
    Rails.cache = ActiveSupport::Cache::NullStore.new
    HardcoverClient.reset_rate_limit_state!

    VCR.turned_off do
      request_stub = stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 429, headers: { "Retry-After" => "120" }, body: "{}")

      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }
      assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.search("test") }

      assert_requested request_stub, times: 1
    end
  end

  test "cache write failures fall back immediately to the process lock" do
    SettingsService.set(:hardcover_api_token, "test_token")
    Rails.cache = Class.new do
      def write(*) = false
      def read(*) = nil
      def delete(*) = false
    end.new
    HardcoverClient.reset_rate_limit_state!

    VCR.turned_off do
      request_stub = stub_hardcover_response

      assert_empty HardcoverClient.search("test")
      assert_requested request_stub, times: 1
    end
  end

  test "an expired lease owner cannot delete a successor lease" do
    SettingsService.set(:hardcover_api_token, "test_token")
    credential = HardcoverClient.send(:current_credential)
    key = HardcoverClient.send(:request_lock_cache_key, credential.digest)
    Rails.cache.write(key, "successor", expires_in: 1.minute)
    expired_at = HardcoverClient.send(:monotonic_time) - HardcoverClient::REQUEST_LOCK_TTL - 1

    HardcoverClient.send(
      :release_request_lock,
      "expired-owner",
      credential.digest,
      acquired_at: expired_at
    )

    assert_equal "successor", Rails.cache.read(key)
    assert_operator HardcoverClient::REQUEST_LOCK_TTL, :>, HardcoverClient::HARD_REQUEST_TIMEOUT
  end

  test "test_connection surfaces rate limiting to health monitoring" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 429, headers: { "Retry-After" => "120" }, body: "{}")

      error = assert_raises(HardcoverClient::RateLimitError) do
        HardcoverClient.test_connection
      end

      assert_equal 120, error.retry_after
    end
  end

  test "test_connection returns true on success" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .with(headers: { "Authorization" => "Bearer test_token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "me" => { "id" => 123 } } }.to_json
        )

      assert HardcoverClient.test_connection
    end
  end

  test "test_connection preserves an existing bearer authorization scheme" do
    SettingsService.set(:hardcover_api_token, "Bearer test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .with(headers: { "Authorization" => "Bearer test_token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "me" => { "id" => 123 } } }.to_json
        )

      assert HardcoverClient.test_connection
    end
  end

  test "test_connection returns false on auth failure" do
    SettingsService.set(:hardcover_api_token, "invalid_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 401, body: '{"error": "Unauthorized"}')

      assert_not HardcoverClient.test_connection
    end
  end

  test "work_id includes source prefix" do
    result = HardcoverClient::SearchResult.new(
      id: "12345",
      title: "Test",
      author: "Author",
      description: nil,
      release_year: 2020,
      cover_url: nil,
      has_audiobook: true,
      has_ebook: true,
      series_name: nil,
      series_position: nil
    )

    assert_equal "hardcover:12345", result.work_id
  end

  private

  def stub_hardcover_response(headers: {})
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" }.merge(headers),
        body: empty_search_body
      )
  end

  def empty_search_body
    {
      "data" => {
        "search" => {
          "results" => {
            "facet_counts" => [],
            "found" => 0,
            "hits" => [],
            "request_params" => {},
            "search_cutoff" => false,
            "search_time_ms" => 1
          }
        }
      }
    }.to_json
  end

  def stub_hardcover_search(query, results)
    typesense_response = {
      "facet_counts" => [],
      "found" => results.size,
      "hits" => results.map { |r| { "document" => r } },
      "request_params" => {},
      "search_cutoff" => false,
      "search_time_ms" => 5
    }

    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "search" => { "results" => typesense_response } } }.to_json
      )
  end

  def stub_hardcover_book(id, book_data)
    books = book_data ? [ book_data ] : []
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "books" => books } }.to_json
      )
  end

  def stub_hardcover_series_books(id, name, book_series)
    stub_request(:post, HardcoverClient::BASE_URL)
      .with { |request| request.body.include?("GetSeriesBooks") && request.body.include?(id.to_s) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "series" => [ { "id" => id, "name" => name, "book_series" => book_series } ] } }.to_json
      )
  end
end
