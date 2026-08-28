# frozen_string_literal: true

require "test_helper"

# Test that Hardcover API calls stay within reasonable quota limits
# to avoid burning through the free plan's ~5000 daily requests
class HardcoverQuotaTest < ActiveSupport::TestCase
  setup do
    @original_token = SettingsService.get(:hardcover_api_token)
    SettingsService.set(:hardcover_api_token, "test_token")
    HardcoverClient.reset_connection!
    
    @api_call_count = 0
    
    # Track all API calls made to Hardcover
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return do |request|
        @api_call_count += 1
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "me" => [ { "id" => 123 } ] } }.to_json
        }
      end
  end

  teardown do
    SettingsService.set(:hardcover_api_token, @original_token || "")
    HardcoverClient.reset_connection!
  end

  test "search respects the configured search limit setting" do
    limit = 5
    SettingsService.set(:hardcover_search_limit, limit)

    # Stub a search that would return many results if limit wasn't enforced
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "data" => {
            "search" => {
              "results" => {
                "hits" => Array.new(limit) do |i|
                  {
                    "document" => {
                      "id" => i + 1,
                      "title" => "Book #{i + 1}",
                      "author_names" => [ "Author #{i + 1}" ]
                    }
                  }
                end
              }
            }
          }
        }.to_json
      )

    results = HardcoverClient.search("test query")

    # Should return exactly limit results, not more
    assert_equal limit, results.size, "Search should respect the configured limit"

    # Verify the API request included the correct limit parameter
    assert_requested(:post, HardcoverClient::BASE_URL) do |req|
      body = JSON.parse(req.body)
      body.dig("variables", "perPage") == limit
    end
  end

  test "search does not make multiple API calls per result" do
    limit = 10
    SettingsService.set(:hardcover_search_limit, limit)

    stub_hardcover_search_response(limit)

    initial_count = @api_call_count
    HardcoverClient.search("test query")
    calls_made = @api_call_count - initial_count

    # Should make exactly ONE API call for a search, not one per result
    assert_equal 1, calls_made, 
      "Search should make only 1 API call total, not one per result"
  end

  test "health check test_connection makes only one API call" do
    initial_count = @api_call_count
    HardcoverClient.test_connection
    calls_made = @api_call_count - initial_count

    assert_equal 1, calls_made,
      "test_connection should make exactly 1 API call"
  end

  test "MetadataService search does not call Hardcover per provider result" do
    SettingsService.set(:hardcover_search_limit, 10)
    
    # Enable only Hardcover
    SettingsService.set(:metadata_providers, [ "hardcover" ])

    stub_hardcover_search_response(10)

    initial_count = @api_call_count
    MetadataService.search("test query")
    calls_made = @api_call_count - initial_count

    # Should make exactly ONE call to Hardcover for the search
    assert_equal 1, calls_made,
      "MetadataService search should make only 1 Hardcover API call"
  end

  test "repeated health checks respect the configured interval" do
    SettingsService.set(:health_check_interval, 300) # 5 minutes
    
    # Create initial health record
    health = SystemHealth.for_service("hardcover")
    health.update!(last_check_at: 10.minutes.ago)

    # First check should run (interval has passed)
    initial_count = @api_call_count
    HealthCheckJob.perform_now(scheduled: true)
    assert_equal 1, @api_call_count - initial_count,
      "First health check should call Hardcover API"

    health.reload
    first_check_time = health.last_check_at

    # Second check immediately after should NOT run (interval hasn't passed)
    HealthCheckJob.perform_now(scheduled: true)
    assert_equal 1, @api_call_count - initial_count,
      "Second immediate health check should not call Hardcover API (interval not elapsed)"

    health.reload
    assert_equal first_check_time, health.last_check_at,
      "Health check timestamp should not change when interval hasn't elapsed"
  end

  test "handles 429 rate limit response gracefully" do
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(status: 429, body: '{"error": "Rate limit exceeded"}')

    assert_raises HardcoverClient::RateLimitError do
      HardcoverClient.search("test")
    end
  end

  test "book details lookup makes only one API call" do
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "data" => {
            "books" => [
              {
                "id" => 12345,
                "title" => "Test Book",
                "contributions" => [ { "author" => { "name" => "Test Author" } } ]
              }
            ]
          }
        }.to_json
      )

    initial_count = @api_call_count
    HardcoverClient.book(12345)
    calls_made = @api_call_count - initial_count

    assert_equal 1, calls_made,
      "Book details lookup should make exactly 1 API call"
  end

  test "series_books makes only one API call" do
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "data" => {
            "series" => [
              {
                "id" => 987,
                "name" => "Test Series",
                "book_series" => [
                  {
                    "position" => 1,
                    "book" => {
                      "id" => 111,
                      "title" => "Book 1",
                      "contributions" => [ { "author" => { "name" => "Author" } } ]
                    }
                  }
                ]
              }
            ]
          }
        }.to_json
      )

    initial_count = @api_call_count
    HardcoverClient.series_books(987)
    calls_made = @api_call_count - initial_count

    assert_equal 1, calls_made,
      "Series books lookup should make exactly 1 API call"
  end

  private

  def stub_hardcover_search_response(result_count)
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "data" => {
            "search" => {
              "results" => {
                "hits" => Array.new(result_count) do |i|
                  {
                    "document" => {
                      "id" => i + 1,
                      "title" => "Book #{i + 1}",
                      "author_names" => [ "Author #{i + 1}" ],
                      "cached_image" => "https://example.com/cover#{i + 1}.jpg"
                    }
                  }
                end
              }
            }
          }
        }.to_json
      )
  end
end
