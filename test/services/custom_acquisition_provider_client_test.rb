# frozen_string_literal: true

require "test_helper"

class CustomAcquisitionProviderClientTest < ActiveSupport::TestCase
  setup do
    @provider = AcquisitionProvider.create!(
      name: "Local Provider",
      url: "http://provider.test",
      api_key: "secret",
      timeout_seconds: 5
    )
    @client = @provider.client
    @request = requests(:pending_request)
  end

  test "search posts request and book context and parses results" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .with do |request|
          body = JSON.parse(request.body)
          request.headers["Authorization"] == "Bearer secret" &&
            body["book"]["title"] == @request.book.title &&
            body["book"]["book_type"] == "ebook" &&
            body["request"]["language"].present?
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "abc123",
                title: "Provider Result",
                author: "Provider Author",
                format: "epub",
                language: "en",
                size_bytes: 12345,
                download_type: "direct",
                info_url: "https://provider.test/books/abc123"
              }
            ]
          }.to_json
        )

      results = @client.search(@request)

      assert_equal 1, results.size
      assert_equal "abc123", results.first.provider_result_id
      assert_equal "Provider Result", results.first.title
      assert_equal "epub", results.first.file_type
      assert_equal "direct", results.first.download_type
      assert results.first.available?
    end
  end

  test "search infers direct download type from direct_url" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "direct-without-type",
                title: "Provider Direct Result",
                direct_url: "https://files.test/book.epub"
              }
            ]
          }.to_json
        )

      result = @client.search(@request).first

      assert_equal "direct", result.download_type
      assert_equal "https://files.test/book.epub", result.download_url
      assert_equal "direct", result.payload["download_type"]
    end
  end

  test "search infers usenet download type from nzb_url" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "nzb-without-type",
                title: "Provider NZB Result",
                nzb_url: "https://files.test/book.nzb"
              }
            ]
          }.to_json
        )

      result = @client.search(@request).first

      assert_equal "usenet", result.download_type
      assert_equal "https://files.test/book.nzb", result.download_url
      assert_equal "usenet", result.payload["download_type"]
    end
  end

  test "search infers torrent download type from magnet_url" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "magnet-without-type",
                title: "Provider Magnet Result",
                magnet_url: "magnet:?xt=urn:btih:abc123"
              }
            ]
          }.to_json
        )

      result = @client.search(@request).first

      assert_equal "torrent", result.download_type
      assert_equal "magnet:?xt=urn:btih:abc123", result.magnet_url
      assert_equal "torrent", result.payload["download_type"]
    end
  end

  test "search marks unavailable results as not downloadable" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "unavailable",
                title: "Provider Unavailable Result",
                availability: "temporarily_unavailable",
                direct_url: "https://files.test/book.epub"
              }
            ]
          }.to_json
        )

      result = @client.search(@request).first

      assert_equal "temporarily_unavailable", result.availability
      assert_not result.available?
      assert_not result.downloadable?
    end
  end

  test "search rejects non object response body" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: "[]".to_json
        )

      assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end
    end
  end

  test "search rejects non array results container" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { results: "not-a-list" }.to_json
        )

      assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end
    end
  end

  test "search skips malformed result entries" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              "bad-result",
              {
                id: "valid",
                title: "Valid Provider Result",
                direct_url: "https://files.test/book.epub"
              }
            ]
          }.to_json
        )

      results = @client.search(@request)

      assert_equal 1, results.size
      assert_equal "valid", results.first.provider_result_id
    end
  end

  test "search raises ResponseError on non-success status" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(status: 500, body: "boom")

      error = assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end

      assert_includes error.message, "HTTP 500"
    end
  end

  test "search raises ResponseError on invalid JSON" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: "not json {"
        )

      error = assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end

      assert_includes error.message, "invalid JSON"
    end
  end

  test "search raises ConnectionError when connection is refused" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search").to_raise(Errno::ECONNREFUSED)

      assert_raises(CustomAcquisitionProviderClient::ConnectionError) do
        @client.search(@request)
      end
    end
  end

  test "search raises ConnectionError on timeout" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search").to_timeout

      assert_raises(CustomAcquisitionProviderClient::ConnectionError) do
        @client.search(@request)
      end
    end
  end

  test "search rejects responses exceeding the size limit" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: {
            "Content-Type" => "application/json",
            "Content-Length" => (CustomAcquisitionProviderClient::MAX_RESPONSE_BYTES + 1).to_s
          },
          body: "{}"
        )

      error = assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end

      assert_includes error.message, "exceeds"
    end
  end

  test "search rejects streamed bodies exceeding the size limit" do
    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: "x" * (CustomAcquisitionProviderClient::MAX_RESPONSE_BYTES + 1)
        )

      assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.search(@request)
      end
    end
  end

  test "search refuses providers that resolve to private addresses" do
    with_resolver(->(host) { [ "10.0.0.5" ] }) do
      error = assert_raises(CustomAcquisitionProviderClient::ConnectionError) do
        @client.search(@request)
      end

      assert_includes error.message, "Refused to contact"
    end
  end

  test "search allows private provider addresses when allow_private_network is enabled" do
    provider = AcquisitionProvider.create!(
      name: "LAN Provider",
      url: "http://192.168.1.80:4567",
      allow_private_network: true,
      timeout_seconds: 5
    )

    VCR.turned_off do
      stub_request(:post, "http://192.168.1.80:4567/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { results: [] }.to_json
        )

      assert_equal [], provider.client.search(@request)
    end
  end

  test "acquire parses direct artifact" do
    search_result = @request.search_results.create!(
      guid: "custom:#{@provider.id}:abc123",
      title: "Provider Result [EPUB]",
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: @provider,
      provider_result_id: "abc123",
      provider_payload: { "download_type" => "direct" }
    )

    VCR.turned_off do
      stub_request(:post, "http://provider.test/acquire")
        .with do |request|
          body = JSON.parse(request.body)
          body["provider_result_id"] == "abc123"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { download_type: "direct", direct_url: "https://files.test/book.epub" }.to_json
        )

      acquisition = @client.acquire(search_result)

      assert_equal "direct", acquisition.download_type
      assert_equal "https://files.test/book.epub", acquisition.direct_url
    end
  end

  test "acquire rejects missing artifact" do
    search_result = @request.search_results.create!(
      guid: "custom:#{@provider.id}:missing",
      title: "Broken Provider Result",
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: @provider,
      provider_result_id: "missing"
    )

    VCR.turned_off do
      stub_request(:post, "http://provider.test/acquire")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { download_type: "direct" }.to_json
        )

      assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.acquire(search_result)
      end
    end
  end

  test "acquire rejects non object response body" do
    search_result = @request.search_results.create!(
      guid: "custom:#{@provider.id}:bad-body",
      title: "Broken Provider Result",
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: @provider,
      provider_result_id: "bad-body"
    )

    VCR.turned_off do
      stub_request(:post, "http://provider.test/acquire")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: "[]".to_json
        )

      assert_raises(CustomAcquisitionProviderClient::ResponseError) do
        @client.acquire(search_result)
      end
    end
  end

  test "test_connection returns true for healthy providers" do
    VCR.turned_off do
      stub_request(:get, "http://provider.test/health")
        .with(headers: { "Authorization" => "Bearer secret" })
        .to_return(status: 200, body: "ok")

      assert @client.test_connection
    end
  end

  test "test_connection returns false on failure responses and connection errors" do
    VCR.turned_off do
      stub_request(:get, "http://provider.test/health").to_return(status: 500)
      assert_not @client.test_connection

      stub_request(:get, "http://provider.test/health").to_raise(Errno::ECONNREFUSED)
      assert_not @client.test_connection
    end
  end

  test "test_connection returns false for blocked provider URLs" do
    with_resolver(->(host) { [ "10.0.0.5" ] }) do
      assert_not @client.test_connection
    end
  end

  test "normalize_download_type maps aliases to canonical types" do
    assert_equal "direct", CustomAcquisitionProviderClient.normalize_download_type("HTTP")
    assert_equal "torrent", CustomAcquisitionProviderClient.normalize_download_type("magnet")
    assert_equal "usenet", CustomAcquisitionProviderClient.normalize_download_type("nzb")
    assert_equal "weird", CustomAcquisitionProviderClient.normalize_download_type("weird")
    assert_nil CustomAcquisitionProviderClient.normalize_download_type("  ")
    assert_nil CustomAcquisitionProviderClient.normalize_download_type(nil)
  end

  private

  def with_resolver(resolver)
    previous = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = resolver
    yield
  ensure
    OutboundUrlGuard.resolver = previous
  end
end
