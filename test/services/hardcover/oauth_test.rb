# frozen_string_literal: true

require "test_helper"

class Hardcover::OauthTest < ActiveSupport::TestCase
  DISCOVERY = {
    "issuer" => "https://api.hardcover.app",
    "authorization_endpoint" => "https://hardcover.app/oauth2/authorize",
    "token_endpoint" => "https://api.hardcover.app/oauth2/token",
    "revocation_endpoint" => "https://api.hardcover.app/oauth2/revoke",
    "device_authorization_endpoint" => "https://api.hardcover.app/oauth2/device",
    "code_challenge_methods_supported" => [ "S256" ],
    "authorization_response_iss_parameter_supported" => true
  }.freeze
  TOKEN_URL = "https://api.hardcover.app/oauth2/token"

  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    SettingsService.set(:hardcover_oauth_client_secret, "")
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 200, body: DISCOVERY.to_json, headers: { "Content-Type" => "application/json" })
  end

  test "PKCE challenge is the S256 hash of the verifier" do
    verifier, challenge = Hardcover::Oauth.generate_pkce

    assert_operator verifier.length, :>=, 43
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false), challenge
  end

  test "authorization URL requests S256 PKCE, state, and read-only scopes" do
    url = URI.parse(Hardcover::Oauth.authorization_url(state: "state-1", code_challenge: "challenge-1", redirect_uri: "https://shelf.example/hardcover/connection/callback"))
    params = Rack::Utils.parse_query(url.query)

    assert_equal "https://hardcover.app/oauth2/authorize", "#{url.scheme}://#{url.host}#{url.path}"
    assert_equal "code", params["response_type"]
    assert_equal "client-123", params["client_id"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal "challenge-1", params["code_challenge"]
    assert_equal "state-1", params["state"]
    assert_equal "read:me:content read:library read:lists read:catalog", params["scope"]
    assert_not params["scope"].include?("write"), "Shelfarr never asks for write access"
  end

  test "only Hardcover's issuer is accepted on the callback" do
    assert Hardcover::Oauth.valid_issuer?("https://api.hardcover.app")
    assert_not Hardcover::Oauth.valid_issuer?("https://evil.example")
    assert_not Hardcover::Oauth.valid_issuer?(nil)
  end

  test "discovery cannot move endpoints off Hardcover's hosts" do
    with_hardcover_memory_cache do
      stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: DISCOVERY.merge("token_endpoint" => "https://attacker.example/token").to_json
      )

      assert_equal TOKEN_URL, Hardcover::Oauth.endpoint("token_endpoint")
    end
  end

  test "a public client exchanges the code with client_id and the PKCE verifier" do
    stub = stub_request(:post, TOKEN_URL)
      .with(body: hash_including("grant_type" => "authorization_code", "code" => "code-1", "code_verifier" => "verifier-1",
        "redirect_uri" => "https://shelf.example/cb", "client_id" => "client-123"))
      .to_return(status: 200, body: { access_token: "hc_at_1", refresh_token: "hc_rt_1", expires_in: 604_800, scope: "read:library" }.to_json)

    token_set = Hardcover::Oauth.exchange_code(code: "code-1", code_verifier: "verifier-1", redirect_uri: "https://shelf.example/cb")

    assert_requested stub
    assert_equal "hc_at_1", token_set.access_token
    assert_equal "hc_rt_1", token_set.refresh_token
    assert_in_delta 1.week.from_now, token_set.expires_at, 5
  end

  test "a confidential client authenticates with HTTP Basic and omits client_id from the body" do
    SettingsService.set(:hardcover_oauth_client_secret, "s3cret")
    expected = "Basic #{Base64.strict_encode64('client-123:s3cret')}"
    stub = stub_request(:post, TOKEN_URL)
      .with(headers: { "Authorization" => expected }) { |request| !request.body.include?("client_id") }
      .to_return(status: 200, body: { access_token: "hc_at_2", refresh_token: "hc_rt_2", expires_in: 60 }.to_json)

    Hardcover::Oauth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://shelf.example/cb")

    assert_requested stub
  end

  test "a refused code raises AuthorizationError" do
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    error = assert_raises(Hardcover::Oauth::AuthorizationError) do
      Hardcover::Oauth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://shelf.example/cb")
    end
    assert_equal "invalid_grant", error.message
  end

  test "refresh stores the rotated refresh token before anything else can use it" do
    user = users(:one)
    connection = create_hardcover_connection(user, access_token: "hc_at_old", refresh_token: "hc_rt_old", expires_at: 1.minute.from_now)
    stub = stub_request(:post, TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "hc_rt_old"))
      .to_return(status: 200, body: { access_token: "hc_at_new", refresh_token: "hc_rt_new", expires_in: 604_800 }.to_json)

    Hardcover::Oauth.refresh_connection!(connection)

    assert_requested stub, times: 1
    connection.reload
    assert_equal "hc_at_new", connection.access_token
    assert_equal "hc_rt_new", connection.refresh_token
    assert_not connection.access_token_expiring?
  end

  test "refresh is skipped when another process already rotated the token" do
    user = users(:one)
    connection = create_hardcover_connection(user, access_token: "hc_at_old", refresh_token: "hc_rt_old", expires_at: 1.minute.from_now)
    stale_copy = HardcoverConnection.find(connection.id)
    connection.update!(access_token: "hc_at_rotated", refresh_token: "hc_rt_rotated", access_token_expires_at: 1.week.from_now)
    stub = stub_request(:post, TOKEN_URL)

    Hardcover::Oauth.refresh_connection!(stale_copy, force: true)

    assert_not_requested stub
    assert_equal "hc_rt_rotated", stale_copy.refresh_token
  end

  test "device authorization reports pending, slow_down, approval, denial, and expiry" do
    stub_request(:post, "https://api.hardcover.app/oauth2/device")
      .with(body: hash_including("client_id" => "client-123", "scope" => "read:me:content read:library read:lists read:catalog"))
      .to_return(status: 200, body: { device_code: "dev-1", user_code: "ABCD-1234", verification_uri: "https://hardcover.app/link",
        verification_uri_complete: "https://hardcover.app/link?code=ABCD-1234", expires_in: 900, interval: 5 }.to_json)
    start = Hardcover::Oauth.start_device_authorization
    assert_equal "ABCD-1234", start.user_code
    assert_equal 5, start.interval

    stub_request(:post, TOKEN_URL)
      .to_return(status: 400, body: { error: "authorization_pending" }.to_json)
      .then.to_return(status: 400, body: { error: "slow_down" }.to_json)
      .then.to_return(status: 200, body: { access_token: "hc_at_dev", refresh_token: "hc_rt_dev", expires_in: 604_800 }.to_json)
      .then.to_return(status: 400, body: { error: "access_denied" }.to_json)
      .then.to_return(status: 400, body: { error: "expired_token" }.to_json)

    assert_equal :pending, Hardcover::Oauth.poll_device_authorization("dev-1").status
    slow = Hardcover::Oauth.poll_device_authorization("dev-1")
    assert_equal :slow_down, slow.status
    assert_equal 5, slow.interval
    approved = Hardcover::Oauth.poll_device_authorization("dev-1")
    assert_equal "hc_at_dev", approved.token_set.access_token
    assert_equal :denied, Hardcover::Oauth.poll_device_authorization("dev-1").status
    assert_equal :expired, Hardcover::Oauth.poll_device_authorization("dev-1").status
  end

  test "device sign-in rejects verification links outside Hardcover" do
    stub_request(:post, "https://api.hardcover.app/oauth2/device")
      .to_return(status: 200, body: { device_code: "d", user_code: "WXYZ-0000", verification_uri: "https://phish.example/link", interval: 5, expires_in: 600 }.to_json)

    assert_equal "https://hardcover.app/link", Hardcover::Oauth.start_device_authorization.verification_uri
  end

  test "revocation failures do not raise" do
    stub_request(:post, "https://api.hardcover.app/oauth2/revoke").to_timeout

    assert_not Hardcover::Oauth.revoke("hc_rt_x")
  end
end
