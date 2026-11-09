# frozen_string_literal: true

require "test_helper"

class Kobo::StoreProxyTest < ActiveSupport::TestCase
  setup { @proxy = Kobo::StoreProxy.new }

  test "relays only the reader's protocol headers to the fixed Store origin" do
    stub = stub_request(:get, "https://storeapi.kobo.com/v1/user/profile?a=1").with { |request|
      request.headers["Authorization"] == "Bearer reader-own" && request.headers["X-Kobo-Deviceid"] == "device" &&
        request.headers["X-Kobo-Synctoken"].nil? && request.headers["Cookie"].nil? &&
        request.headers["X-Forwarded-For"].nil? && request.headers["Accept-Encoding"] == "identity"
    }.to_return(body: "{}", headers: { "Content-Type" => "application/json", "Set-Cookie" => "synthetic", "X-Kobo-Apitoken" => "e30=",
      "Strict-Transport-Security" => "max-age=1" })
    response = @proxy.call(method: "GET", path: "/v1/user/profile", query: "a=1",
      headers: { "authorization" => "Bearer reader-own", "x-kobo-deviceid" => "device", "x-kobo-synctoken" => "sf2.shelfarr",
        "cookie" => "session_id=private", "x-forwarded-for" => "10.0.0.1", "x-kobo-bad" => "a\r\nInjected: yes" })
    assert_requested stub
    assert_equal 200, response.status
    assert_equal({ "x-kobo-apitoken" => "e30=", "content-type" => "application/json; charset=utf-8" }, response.headers)
  end

  test "the Store cursor sent is the one Shelfarr chose, never the reader's combined cursor" do
    stub_request(:get, "https://storeapi.kobo.com/v1/library/sync").with(headers: { "X-Kobo-Synctoken" => "store-part" }).to_return(body: "[]")
    @proxy.call(method: "GET", path: "/v1/library/sync", headers: { "x-kobo-synctoken" => "sf2.combined" }, sync_token: "store-part")
    assert_requested :get, "https://storeapi.kobo.com/v1/library/sync", times: 1
  end

  test "redirects, compression, oversized bodies and network failures are unavailable" do
    url = "https://storeapi.kobo.com/v1/library/sync"
    [ 301, 302, 307, 308 ].each do |status|
      stub_request(:get, url).to_return(status: status, headers: { "Location" => "https://evil.example/collect" })
      assert_raises(Kobo::StoreProxy::Unavailable) { @proxy.call(method: "GET", path: "/v1/library/sync") }
    end
    assert_not_requested :get, "https://evil.example/collect"
    stub_request(:get, url).to_return(body: "x", headers: { "Content-Encoding" => "gzip" })
    assert_raises(Kobo::StoreProxy::Unavailable) { @proxy.call(method: "GET", path: "/v1/library/sync") }
    stub_request(:get, url).to_return(body: "x" * (Kobo::StoreProxy::MAX_RESPONSE_BYTES + 1))
    assert_raises(Kobo::StoreProxy::Unavailable) { @proxy.call(method: "GET", path: "/v1/library/sync") }
    stub_request(:get, url).to_timeout
    assert_raises(Kobo::StoreProxy::Unavailable) { @proxy.call(method: "GET", path: "/v1/library/sync") }
  end

  test "Store errors pass through as statuses and non-JSON content is never active" do
    stub_request(:post, "https://storeapi.kobo.com/v1/auth/refresh").with(body: "{}")
      .to_return(status: 401, body: "<script>x</script>", headers: { "Content-Type" => "text/html", "WWW-Authenticate" => "Bearer" })
    response = @proxy.call(method: "POST", path: "/v1/auth/refresh", headers: { "content-type" => "application/json" }, body: "{}")
    assert_equal 401, response.status
    assert_equal "text/plain; charset=utf-8", response.headers["content-type"]
    assert_equal "Bearer", response.headers["www-authenticate"]
  end

  test "paths, methods, queries and bodies outside the Store protocol are refused before any request" do
    [ "https://evil.example/v1/x", "//evil.example/v1/x", "/v1/../admin", "/v1/%2e%2e/admin", "/v1/a%2fb", "/v1//x",
      "/other/path", "/v1/x\r\nHost: evil.example", "/v1/x?y", "/v1/x#y", "v1/x" ].each do |path|
      assert_raises(Kobo::StoreProxy::InvalidRequest, path) { @proxy.call(method: "GET", path: path) }
    end
    assert_raises(Kobo::StoreProxy::InvalidRequest) { @proxy.call(method: "TRACE", path: "/v1/x") }
    assert_raises(Kobo::StoreProxy::InvalidRequest) { @proxy.call(method: "GET", path: "/v1/x", query: "a=1\r\nb") }
    assert_raises(Kobo::StoreProxy::InvalidRequest) { @proxy.call(method: "POST", path: "/v1/x", body: "x" * (KoboBodyLimit::MAX_BYTES + 1)) }
    assert_not_requested :any, /.*/
  end
end
