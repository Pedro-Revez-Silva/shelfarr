# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/android_updates_test_helper"

class AndroidUpdates::FetcherTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper

  APK = "#{AndroidUpdatesTestHelper::RELEASE_DOWNLOADS}/v1/app.apk".freeze
  ASSET = "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sig=secret-token".freeze

  setup do
    @fetcher = AndroidUpdates::Fetcher.new(AndroidUpdates::Configuration.new({}).source_policy)
  end

  def download(url = APK, max_bytes: 1000)
    received = +""
    size = @fetcher.artifact(URI.parse(url), max_bytes: max_bytes) { |chunk| received << chunk }
    [ size, received ]
  end

  def assert_category(category, &block)
    error = assert_raises(AndroidUpdates::Fetcher::Error, &block)
    assert_equal category, error.category
    assert_not_includes error.message, "secret-token"
    error
  end

  test "follows GitHub's release redirect and sends no credentials" do
    stub_request(:get, APK).to_return(status: 302, headers: { "Location" => ASSET })
    stub_request(:get, ASSET).to_return(status: 200, body: "apk bytes")

    assert_equal [ 9, "apk bytes" ], download

    [ APK, ASSET ].each do |url|
      assert_requested(:get, url) do |request|
        request.headers.keys.none? { |name| %w[Authorization Cookie].include?(name) } &&
          request.headers["Accept-Encoding"] == "identity"
      end
    end
  end

  test "reads the catalog within its size limit" do
    stub_request(:get, CATALOG_URL).to_return(status: 200, body: "{}")

    assert_equal "{}", @fetcher.catalog(URI.parse(CATALOG_URL))
  end

  test "refuses a first request outside the trusted location without connecting" do
    assert_category(:untrusted_location) { download("https://evil.example/app.apk") }
    assert_category(:untrusted_location) { @fetcher.catalog(URI.parse("https://github.com/elsewhere/catalog.json")) }
  end

  test "refuses redirects off the trusted hosts before following them" do
    [
      "https://evil.example/app.apk",
      "http://release-assets.githubusercontent.com/asset",
      "https://user:pass@release-assets.githubusercontent.com/asset",
      "file:///etc/passwd"
    ].each do |location|
      WebMock.reset!
      stub_request(:get, APK).to_return(status: 302, headers: { "Location" => location })

      assert_category(:untrusted_location) { download }
    end
    assert_not_requested(:get, "https://evil.example/app.apk")
  end

  test "stops after five redirects" do
    stub_request(:get, APK).to_return(status: 302, headers: { "Location" => APK })

    assert_category(:too_many_redirects) { download }
    assert_requested(:get, APK, times: 6)
  end

  test "an empty redirect is refused" do
    stub_request(:get, APK).to_return(status: 302, headers: { "Location" => "" })

    assert_category(:bad_redirect) { download }
  end

  test "stops at the declared or streamed size limit" do
    stub_request(:get, APK).to_return(status: 200, body: "x" * 20, headers: { "Content-Length" => "20" })
    assert_category(:too_large) { download(max_bytes: 10) }

    stub_request(:get, APK).to_return(status: 200, body: "x" * 20)
    assert_category(:too_large) { download(max_bytes: 10) }
  end

  test "refuses content codings that would change the bytes" do
    stub_request(:get, APK).to_return(status: 200, body: "x", headers: { "Content-Encoding" => "gzip" })

    assert_category(:content_encoding) { download }
  end

  test "reports HTTP errors, network failures and timeouts as categories" do
    stub_request(:get, APK).to_return(status: 404)
    assert_category(:http_status) { download }

    stub_request(:get, APK).to_raise(SocketError.new("getaddrinfo failed"))
    assert_category(:network) { download }

    stub_request(:get, APK).to_timeout
    assert_category(:network) { download }

    stub_request(:get, APK).to_raise(OpenSSL::SSL::SSLError.new("certificate verify failed"))
    assert_category(:tls) { download }
  end

  test "never reaches private addresses for the official publisher" do
    original = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = ->(_host) { [ "10.0.0.5" ] }

    assert_category(:untrusted_location) { download }
  ensure
    OutboundUrlGuard.resolver = original
  end

  test "a custom publisher may live on the operator's network but never on metadata addresses" do
    policy = AndroidUpdates::Configuration.new(
      "ANDROID_UPDATE_CATALOG_URL" => "https://updates.lan/catalog.json"
    ).source_policy
    fetcher = AndroidUpdates::Fetcher.new(policy)
    original = OutboundUrlGuard.resolver
    stub_request(:get, "https://updates.lan/catalog.json").to_return(status: 200, body: "{}")

    OutboundUrlGuard.resolver = ->(_host) { [ "192.168.1.20" ] }
    assert_equal "{}", fetcher.catalog(URI.parse("https://updates.lan/catalog.json"))

    OutboundUrlGuard.resolver = ->(_host) { [ "169.254.169.254" ] }
    assert_category(:untrusted_location) { fetcher.catalog(URI.parse("https://updates.lan/catalog.json")) }
  ensure
    OutboundUrlGuard.resolver = original
  end
end
