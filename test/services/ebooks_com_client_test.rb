# frozen_string_literal: true

require "test_helper"

class EbooksComClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "pt")
    SettingsService.set(:ebooks_com_search_limit, 5)
    EbooksComClient.reset_connection!
  end

  teardown do
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
    SettingsService.set(:ebooks_com_search_limit, 5)
    EbooksComClient.reset_connection!
  end

  test "search raises when store offers are disabled" do
    SettingsService.set(:ebooks_com_enabled, false)

    assert_raises EbooksComClient::NotConfiguredError do
      EbooksComClient.search(title: "The Moonstone")
    end
  end

  test "cached catalog quotes expire before visible store offers" do
    assert_operator EbooksComClient::CACHE_TTL, :<, StoreOffer::FRESHNESS_TTL
  end

  test "configuration rejects alphabetic values that are not ISO country codes" do
    SettingsService.set(:ebooks_com_country_code, "XX")

    assert_not EbooksComClient.configured?
    assert_not EbooksComClient.valid_country_code?("XX")
    assert EbooksComClient.valid_country_code?("pt")
  end

  test "search does not send control-bearing catalog queries" do
    assert_empty EbooksComClient.search(title: "Private\nTitle")
    assert_not_requested :get, %r{\Ahttps://api\.ebooks\.com/}
  end

  test "search uses ISBN first and returns localized DRM-free offers" do
    exact = book_payload
    stub_ebooks_response("/v2/PT/book/isbn/9781480484160", results: [ exact ])

    results = EbooksComClient.search(
      title: "The Moonstone",
      author: "Wilkie Collins",
      isbn: "978-1-4804-8416-0",
      language: "en"
    )

    assert_equal 1, results.size
    result = results.first
    assert_equal "347175270", result.id
    assert_equal "Wilkie Collins", result.author
    assert_equal [ "9781480484160" ], result.isbns
    assert_equal "en", result.language
    assert_equal [ "epub" ], result.formats
    assert_equal "PT", result.market
    assert_equal "Watermarked", result.drm_type
    assert_equal BigDecimal("7.41"), result.price_amount
    assert_equal "EUR", result.price_currency
    assert_equal "7,41 €", result.localized_price
    assert_equal "https://www.ebooks.com/en-pt/book/347175270/the-moonstone/wilkie-collins/", result.storefront_url
    assert_equal "https://www.ebooks.com/en-pt/cart/add/347175270/", result.checkout_url
    assert_in_delta Time.current.to_f, result.quoted_at.to_f, 1
    assert_not_requested :get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search}
  end

  test "search falls back to title when ISBN has no exact eligible offer" do
    stub_ebooks_response("/v2/PT/book/isbn/9781480484160", results: [])
    search_stub = stub_ebooks_search(results: [ book_payload ])

    results = EbooksComClient.search(
      title: "The Moonstone",
      author: "Wilkie Collins",
      isbn: "9781480484160"
    )

    assert_equal [ "347175270" ], results.map(&:id)
    assert_requested :get, "https://api.ebooks.com/v2/PT/book/isbn/9781480484160", times: 1
    assert_requested search_stub, times: 1
  end

  test "search does not send an invalid ISBN checksum to the edition endpoint" do
    search_stub = stub_ebooks_search(results: [ book_payload ])

    results = EbooksComClient.search(
      title: "The Moonstone",
      author: "Wilkie Collins",
      isbn: "9781480484161"
    )

    assert_equal [ "347175270" ], results.map(&:id)
    assert_requested search_stub, times: 1
    assert_not_requested :get, %r{/book/isbn/}
  end

  test "search snapshots its buyer market across all requests" do
    stub_request(:get, "https://api.ebooks.com/v2/PT/book/isbn/9781480484160")
      .to_return do
        SettingsService.set(:ebooks_com_country_code, "US")
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { generatedAt: "2026-07-17T14:13:27Z", results: [] }.to_json
        }
      end
    search_stub = stub_ebooks_search(results: [ book_payload ])

    result = EbooksComClient.search(
      title: "The Moonstone",
      author: "Wilkie Collins",
      isbn: "9781480484160"
    ).sole

    assert_equal "PT", result.market
    assert_equal "US", SettingsService.get(:ebooks_com_country_code)
    assert_requested search_stub, times: 1
    assert_not_requested :get, %r{\Ahttps://api\.ebooks\.com/v2/US/book/search}
  end

  test "search filters protected, wrong-language, irrelevant, and unsafe offers" do
    protected_book = book_payload(id: 2).tap { |book| book[:drm][:drmFreeAvailable] = false }
    wrong_language = book_payload(id: 3).tap { |book| book[:language] = { code: "fra", name: "French" } }
    unrelated = book_payload(id: 4, title: "The Glen Rose Moonshine Raid", author: "Martin Brown")
    unsafe = book_payload(id: 5).merge(storefrontUrl: "https://attacker.example/book/5")
    stub_ebooks_search(results: [ protected_book, wrong_language, unrelated, unsafe ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins", language: "en")
  end

  test "search requires a downloadable EPUB or PDF format" do
    online_only = book_payload.tap do |book|
      book[:formats] = { epub: false, pdf: false, onlineReader: true }
    end
    stub_ebooks_search(results: [ online_only ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
  end

  test "search rejects a price quoted for another buyer market" do
    wrong_market = book_payload.tap { |book| book[:price][:countryCode] = "US" }
    stub_ebooks_search(results: [ wrong_market ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
  end

  test "search rejects a storefront URL localized for another buyer market" do
    wrong_market_url = book_payload.merge(
      storefrontUrl: "https://www.ebooks.com/en-us/book/347175270/the-moonstone/wilkie-collins/"
    )
    stub_ebooks_search(results: [ wrong_market_url ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
  end

  test "search rejects a safe-hosted storefront URL for another product" do
    wrong_product_url = book_payload.merge(
      storefrontUrl: "https://www.ebooks.com/en-pt/book/999/the-moonstone/wilkie-collins/"
    )
    stub_ebooks_search(results: [ wrong_product_url ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
  end

  test "search drops non-finite negative and out-of-range prices without dropping valid offers" do
    malformed_prices = [ "NaN", "Infinity", "-1", "100000000" ]
    offers = malformed_prices.each_with_index.map do |price, index|
      book_payload(id: index + 10).tap { |book| book[:price][:value] = price }
    end
    offers << book_payload(id: 99, price: 8.25)
    stub_ebooks_search(results: offers)

    results = EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")

    assert_equal 5, results.size
    assert_equal 4, results.count { |result| result.price_amount.nil? }
    assert_includes results.map(&:price_amount), BigDecimal("8.25")
    assert results.reject { |result| result.price_amount }.all? { |result| result.localized_price.nil? }
  end

  test "search hides an upstream display price unless numeric amount and ISO currency agree" do
    invalid_currency = book_payload.tap { |book| book[:price][:currency] = "EURO" }
    stub_ebooks_search(results: [ invalid_currency ])

    result = EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins").sole

    assert_nil result.price_amount
    assert_nil result.price_currency
    assert_nil result.localized_price
  end

  test "search ignores malformed nested result objects without leaking type errors" do
    malformed_drm = book_payload(id: 1).merge(drm: "changed upstream")
    malformed_formats = book_payload(id: 2).merge(formats: [ "epub" ])
    malformed_author = book_payload(id: 3).merge(authors: "changed upstream")
    stub_ebooks_search(results: [ malformed_drm, malformed_formats, malformed_author ])

    assert_empty EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
  end

  test "search rejects short-title containment and a mismatched author" do
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .with(query: hash_including("title" => "It", "author" => "Stephen King", "drmFree" => "true"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          generatedAt: "2026-07-17T14:13:27Z",
          results: [ book_payload(title: "IT Management", author: "Jane Smith") ]
        }.to_json
      )

    assert_empty EbooksComClient.search(title: "It", author: "Stephen King")
  end

  test "search accepts an exact short title with the matching author" do
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .with(query: hash_including("title" => "It", "author" => "Stephen King", "drmFree" => "true"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          generatedAt: "2026-07-17T14:13:27Z",
          results: [ book_payload(title: "It", author: "Stephen King") ]
        }.to_json
      )

    assert_equal [ "It" ], EbooksComClient.search(title: "It", author: "Stephen King").map(&:title)
  end

  test "search wraps malformed successful responses as provider errors" do
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .with(query: hash_including("title" => "The Moonstone", "drmFree" => "true"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { generatedAt: "2026-07-17T14:13:27Z", results: [ "not-a-book" ] }.to_json
      )

    error = assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone")
    end
    assert_equal "eBooks.com returned an invalid book result", error.message
  end

  test "search rejects a response whose declared body exceeds the wire limit" do
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "Content-Length" => (EbooksComClient::MAX_RESPONSE_BYTES + 1).to_s
        },
        body: { results: [] }.to_json
      )

    error = assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone")
    end

    assert_match(/response exceeds/, error.message)
  end

  test "search stops reading a chunked body at the wire limit" do
    oversized_body = " " * (EbooksComClient::MAX_RESPONSE_BYTES + 1)
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: oversized_body)

    error = assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone")
    end

    assert_match(/response exceeds/, error.message)
  end

  test "search bounds JSON nesting and result count" do
    nested_body = '{"results":[],"nested":' + ('{"value":' * EbooksComClient::MAX_JSON_NESTING) +
      "null" + ("}" * EbooksComClient::MAX_JSON_NESTING) + "}"
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: nested_body)

    assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone")
    end

    EbooksComClient.reset_connection!
    too_many = Array.new(EbooksComClient::MAX_UPSTREAM_RESULTS + 1) { |index| book_payload(id: index + 1) }
    stub_ebooks_search(results: too_many)

    error = assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins")
    end
    assert_match(/too many results/, error.message)
  end

  test "search ignores oversized contract fields and keeps a bounded valid result" do
    oversized_title = book_payload(id: 1, title: "A" * (EbooksComClient::MAX_TITLE_LENGTH + 1))
    oversized_authors = book_payload(id: 2).tap do |book|
      book[:authors] = Array.new(EbooksComClient::MAX_AUTHORS + 1) { { name: "Wilkie Collins", type: "Author" } }
    end
    oversized_url = book_payload(id: 3).merge(
      storefrontUrl: "https://www.ebooks.com/#{'a' * EbooksComClient::MAX_URL_LENGTH}"
    )
    valid = book_payload(id: 4)
    stub_ebooks_search(results: [ oversized_title, oversized_authors, oversized_url, valid ])

    assert_equal [ "4" ], EbooksComClient.search(
      title: "The Moonstone",
      author: "Wilkie Collins"
    ).map(&:id)
  end

  test "search does not follow upstream redirects" do
    attacker = stub_request(:get, "https://attacker.example/catalog").to_return(status: 200, body: "{}")
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(status: 302, headers: { "Location" => "https://attacker.example/catalog" }, body: "")

    error = assert_raises(EbooksComClient::ConnectionError) do
      EbooksComClient.search(title: "The Moonstone")
    end

    assert_match(/status 302/, error.message)
    assert_not_requested attacker
  end

  test "malformed upstream JSON is never copied into logs or provider errors" do
    secret = "UPSTREAM_SECRET_SHOULD_NOT_BE_LOGGED"
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{#{secret}")
    messages = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| messages << message }

    Rails.stub(:logger, logger) do
      assert_not EbooksComClient.test_connection
    end

    assert messages.any?
    assert_not_includes messages.join, secret
    assert_match(/EbooksComClient::ConnectionError/, messages.join)
  end

  test "search treats nullable results as an empty successful response" do
    stub_request(:get, "https://api.ebooks.com/v2/PT/book/search")
      .with(query: hash_including("title" => "The Moonstone", "drmFree" => "true"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { generatedAt: "2026-07-17T14:13:27Z", results: nil }.to_json
      )

    assert_empty EbooksComClient.search(title: "The Moonstone")
  end

  test "search clamps the configured result limit" do
    SettingsService.set(:ebooks_com_search_limit, 1)
    stub_ebooks_search(results: [
      book_payload(id: 1),
      book_payload(id: 2, price: 8.25)
    ])

    assert_equal 1, EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins").size
  end

  test "search reports rate limiting" do
    stub_request(:get, "https://api.ebooks.com/v2/PT/book/search")
      .with(query: hash_including("title" => "The Moonstone", "drmFree" => "true"))
      .to_return(status: 429, body: "")

    assert_raises EbooksComClient::RateLimitError do
      EbooksComClient.search(title: "The Moonstone")
    end
  end

  test "rate limiting honors Retry-After and blocks another outbound request during cooldown" do
    with_memory_cache do
      request_stub = stub_request(:get, "https://api.ebooks.com/v2/PT/book/search")
        .with(query: hash_including("title" => "The Moonstone", "drmFree" => "true"))
        .to_return(status: 429, headers: { "Retry-After" => "120" }, body: "")

      first_error = assert_raises(EbooksComClient::RateLimitError) do
        EbooksComClient.search(title: "The Moonstone")
      end
      second_error = assert_raises(EbooksComClient::RateLimitError) do
        EbooksComClient.search(title: "The Moonstone")
      end

      assert_match(/retry in 120 seconds/, first_error.message)
      assert_match(/cooldown active/, second_error.message)
      assert_requested request_stub, times: 1
      assert_in_delta Time.current.to_f + 120, Rails.cache.read(EbooksComClient::RATE_LIMIT_CACHE_KEY), 2
    end
  end

  test "rate limit Retry-After parsing uses a bounded fallback" do
    assert_equal EbooksComClient::DEFAULT_RATE_LIMIT_COOLDOWN,
      EbooksComClient.send(:retry_after_seconds, "not-a-retry-date")
    assert_equal EbooksComClient::MAX_RATE_LIMIT_COOLDOWN,
      EbooksComClient.send(:retry_after_seconds, (EbooksComClient::MAX_RATE_LIMIT_COOLDOWN * 2).to_s)
    assert_equal EbooksComClient::MAX_RATE_LIMIT_COOLDOWN,
      EbooksComClient.send(:retry_after_seconds, "9" * 10_000)
  end

  test "a corrupt non-finite cooldown value does not break catalog access" do
    with_memory_cache do
      Rails.cache.write(EbooksComClient::RATE_LIMIT_CACHE_KEY, Float::INFINITY)
      stub_ebooks_search(results: [ book_payload ])

      assert_equal 1, EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins").size
    end
  end

  test "a corrupt cached payload is discarded and fetched again" do
    with_memory_cache do
      path = "/v2/PT/book/search"
      params = { title: "The Moonstone", author: "Wilkie Collins", drmFree: true }
      cache_key = EbooksComClient.send(:response_cache_key, path, params)
      Rails.cache.write(cache_key, "not-an-array")
      request_stub = stub_ebooks_search(results: [ book_payload ])

      assert_equal 1, EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins").size
      assert_requested request_stub, times: 1
      assert Rails.cache.read(cache_key).is_a?(Array)
    end
  end

  test "identical successful lookups share the bounded response cache" do
    with_memory_cache do
      request_stub = stub_ebooks_search(results: [ book_payload ])

      2.times do
        assert_equal 1, EbooksComClient.search(title: "The Moonstone", author: "Wilkie Collins").size
      end

      assert_requested request_stub, times: 1
    end
  end

  test "the shared cache lease serializes callers independently of the process mutex" do
    with_memory_cache do
      active = 0
      maximum_active = 0
      counter_mutex = Mutex.new

      workers = 2.times.map do
        Thread.new do
          EbooksComClient.send(:with_shared_request_lock) do
            counter_mutex.synchronize do
              active += 1
              maximum_active = [ maximum_active, active ].max
            end
            sleep 0.05
          ensure
            counter_mutex.synchronize { active -= 1 }
          end
        end
      end
      workers.each(&:value)

      assert_equal 1, maximum_active
    end
  end

  test "outbound catalog requests are serialized within the process" do
    with_memory_cache do
      active_requests = 0
      maximum_active_requests = 0
      counter_mutex = Mutex.new

      stub_request(:get, %r{https://api\.ebooks\.com/v2/PT/book/search})
        .to_return do
          counter_mutex.synchronize do
            active_requests += 1
            maximum_active_requests = [ maximum_active_requests, active_requests ].max
          end
          sleep 0.05
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { generatedAt: "2026-07-17T14:13:27Z", results: [] }.to_json
          }
        ensure
          counter_mutex.synchronize { active_requests -= 1 }
        end

      threads = 2.times.map do |index|
        Thread.new do
          EbooksComClient.send(
            :fetch_uncached_results,
            "/v2/PT/book/search",
            title: "Serialized request #{index}",
            drmFree: true
          )
        end
      end
      threads.each(&:value)

      assert_equal 1, maximum_active_requests
    end
  end

  test "test_connection returns false when the catalog is unreachable" do
    stub_request(:get, "https://api.ebooks.com/v2/PT/book/search")
      .with(query: hash_including("title" => "The Moonstone", "drmFree" => "true"))
      .to_raise(Faraday::ConnectionFailed.new("offline"))

    assert_not EbooksComClient.test_connection
  end

  test "test_connection does not report a missing catalog endpoint as healthy" do
    stub_request(:get, %r{\Ahttps://api\.ebooks\.com/v2/PT/book/search})
      .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "{}")

    assert_not EbooksComClient.test_connection
  end

  private

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end

  def stub_ebooks_search(results:)
    stub_ebooks_response(
      "/v2/PT/book/search",
      results: results,
      query: hash_including(
        "title" => "The Moonstone",
        "author" => "Wilkie Collins",
        "drmFree" => "true"
      )
    )
  end

  def stub_ebooks_response(path, results:, query: nil)
    request = stub_request(:get, "https://api.ebooks.com#{path}")
    request = request.with(query: query) if query
    request.to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        generatedAt: "2026-07-17T14:13:27Z",
        totalResults: results.length,
        results: results
      }.to_json
    )
  end

  def book_payload(id: 347_175_270, title: "The Moonstone", author: "Wilkie Collins", price: 7.41, isbns: [ "9781480484160" ])
    {
      id: id,
      title: title,
      storefrontUrl: "https://www.ebooks.com/en-pt/book/#{id}/the-moonstone/wilkie-collins/",
      addToCartUrl: "https://www.ebooks.com/en-pt/cart/add/#{id}/",
      coverImageUrl: "https://image.ebooks.com/previews/000/000419/000419200/000419200-hq-168-80.jpg",
      isbns: isbns,
      authors: [ { name: author, type: "Author" } ],
      price: {
        currency: "EUR",
        countryCode: "PT",
        value: price,
        localisedValue: "7,41 €"
      },
      drm: {
        drmFreeAvailable: true,
        drmFreeType: "Watermarked"
      },
      formats: {
        epub: true,
        pdf: false,
        onlineReader: true
      },
      language: {
        code: "eng",
        name: "English"
      }
    }
  end
end
