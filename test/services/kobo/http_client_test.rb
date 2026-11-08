# frozen_string_literal: true

require "test_helper"

class Kobo::HttpClientTest < ActiveSupport::TestCase
  setup { @client = Kobo::HttpClient.new }

  test "redirects never receive credentials and provider errors contain only a category" do
    [ 301, 302, 307, 308, 400, 401, 403, 429, 500 ].each do |status|
      stub_request(:get, "https://storeapi.kobo.com/v1/library/sync").to_return(status: status,
        headers: { "Location" => "https://evil.example/private" }, body: "synthetic-private-provider-error")
      error = assert_raises(Kobo::HttpClient::Error) do
        @client.call(origin: :store, path: "/v1/library/sync", headers: { "Authorization" => "Bearer synthetic" })
      end
      assert_not_includes error.message, "synthetic"
    end
    assert_not_requested :get, "https://evil.example/private"
  end

  test "overlarge compressed timed out and malformed requests fail without fallback" do
    url = "https://storeapi.kobo.com/v1/library/sync"
    stub_request(:get, url).to_return(body: "x" * (Kobo::HttpClient::MAX_BYTES + 1))
    assert_raises(Kobo::HttpClient::Error) { @client.call(origin: :store, path: "/v1/library/sync") }
    stub_request(:get, url).to_return(body: "abc", headers: { "Content-Encoding" => "gzip" })
    assert_raises(Kobo::HttpClient::Error) { @client.call(origin: :store, path: "/v1/library/sync") }
    stub_request(:get, url).to_timeout
    assert_equal "provider_unavailable", assert_raises(Kobo::HttpClient::Error) { @client.call(origin: :store, path: "/v1/library/sync") }.code
    [ "https://evil.example", "//evil.example/path", "/path\r\nHost: evil.example" ].each do |path|
      assert_raises(Kobo::HttpClient::Error) { @client.call(origin: :store, path: path) }
    end
  end

  test "response exposes only Kobo protocol headers" do
    stub_request(:get, "https://storeapi.kobo.com/v1/library/sync").to_return(body: "[]",
      headers: { "Set-Cookie" => "synthetic", "X-Kobo-Synctoken" => "page-2", "Location" => "https://evil.example" })
    response = @client.call(origin: :store, path: "/v1/library/sync")
    assert_equal({ "x-kobo-synctoken" => "page-2" }, response.headers)
  end
end
