# frozen_string_literal: true

require "test_helper"

class Hardcover::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  TOKEN_URL = "https://api.hardcover.app/oauth2/token"

  setup do
    @user = users(:one)
    sign_in_as(@user)
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    SettingsService.set(:hardcover_oauth_client_secret, "")
    SettingsService.set(:hardcover_oauth_redirect_uri, "https://shelf.example/hardcover/connection/callback")
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 404)
  end

  def start_oauth
    post authorize_hardcover_connection_path
    assert_response :redirect
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  test "sign-in redirects to Hardcover with PKCE and a state bound to this session" do
    params = start_oauth

    assert response.location.start_with?("https://hardcover.app/oauth2/authorize?")
    assert_equal "S256", params["code_challenge_method"]
    assert params["state"].length >= 32
    assert_equal "https://shelf.example/hardcover/connection/callback", params["redirect_uri"]
  end

  test "sign-in refuses a non-HTTPS redirect address" do
    SettingsService.set(:hardcover_oauth_redirect_uri, "http://shelf.lan:3000/hardcover/connection/callback")

    post authorize_hardcover_connection_path

    assert_redirected_to profile_path
    assert_match(/HTTPS/, flash[:alert])
  end

  test "a successful callback stores encrypted tokens and never shows them" do
    params = start_oauth
    stub_request(:post, TOKEN_URL)
      .with(body: hash_including("code" => "auth-code", "redirect_uri" => "https://shelf.example/hardcover/connection/callback"))
      .to_return(status: 200, body: { access_token: "hc_at_secret", refresh_token: "hc_rt_secret", expires_in: 604_800, scope: "read:library" }.to_json)
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 4242, "username" => "reader" } ] })

    get callback_hardcover_connection_path, params: { code: "auth-code", state: params["state"], iss: "https://api.hardcover.app" }

    assert_redirected_to hardcover_subscriptions_path
    connection = @user.reload.hardcover_connection
    assert_equal [ 4242, "reader", "oauth" ], [ connection.hardcover_user_id, connection.hardcover_username, connection.auth_method ]
    raw = HardcoverConnection.connection.select_one("SELECT access_token, refresh_token FROM hardcover_connections WHERE id = #{connection.id}")
    assert_not_includes raw["access_token"], "hc_at_secret"
    assert_not_includes raw["refresh_token"], "hc_rt_secret"
    assert_includes connection.inspect, "[FILTERED]"
    assert_equal "Bearer hc_at_secret", hardcover_requests.last[:authorization]

    get profile_path
    assert_not_includes response.body, "hc_at_secret"
    assert_not_includes response.body, "hc_rt_secret"
    assert_includes response.body, "@reader"
  end

  test "a callback with the wrong state is rejected without redeeming the code" do
    start_oauth
    token = stub_request(:post, TOKEN_URL)

    get callback_hardcover_connection_path, params: { code: "auth-code", state: "forged", iss: "https://api.hardcover.app" }

    assert_redirected_to profile_path
    assert_not_requested token
    assert_nil @user.reload.hardcover_connection
  end

  test "a callback from the wrong issuer is rejected" do
    params = start_oauth
    token = stub_request(:post, TOKEN_URL)

    get callback_hardcover_connection_path, params: { code: "auth-code", state: params["state"], iss: "https://evil.example" }

    assert_redirected_to profile_path
    assert_not_requested token
  end

  test "a state can only be used once" do
    params = start_oauth
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    get callback_hardcover_connection_path, params: { code: "c", state: params["state"], iss: "https://api.hardcover.app" }

    get callback_hardcover_connection_path, params: { code: "c", state: params["state"], iss: "https://api.hardcover.app" }

    assert_requested :post, TOKEN_URL, times: 1
    assert_match(/expired or was started elsewhere/, flash[:alert])
  end

  test "a cancelled sign-in is reported" do
    params = start_oauth

    get callback_hardcover_connection_path, params: { error: "access_denied", state: params["state"], iss: "https://api.hardcover.app" }

    assert_redirected_to profile_path
    assert_equal "Hardcover sign-in was cancelled.", flash[:alert]
  end

  test "personal API keys are refused unless an admin enables them" do
    post hardcover_connection_path, params: { api_key: "hc_pat_value" }

    assert_redirected_to profile_path
    assert_nil @user.reload.hardcover_connection
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "an allowed personal API key is verified, stored, and filtered from logs" do
    SettingsService.set(:hardcover_allow_personal_access, true)
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 77, "username" => "pat_user" } ] })

    post hardcover_connection_path, params: { api_key: "Bearer hc_pat_value" }

    assert_redirected_to hardcover_subscriptions_path
    connection = @user.reload.hardcover_connection
    assert_equal "personal_token", connection.auth_method
    assert_equal "hc_pat_value", connection.access_token
    assert_equal "[FILTERED]", Rails.application.config.filter_parameters.then { |filters| ActiveSupport::ParameterFilter.new(filters).filter("api_key" => "x")["api_key"] }
  end

  test "an invalid personal API key is rejected" do
    SettingsService.set(:hardcover_allow_personal_access, true)
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 401, body: "{}")

    post hardcover_connection_path, params: { api_key: "wrong" }

    assert_redirected_to profile_path
    assert_match(/rejected that key/, flash[:alert])
    assert_nil @user.reload.hardcover_connection
  end

  test "disconnecting revokes the session and pauses Want to Read but keeps requests" do
    create_hardcover_connection(@user, refresh_token: "hc_rt_revoke_me")
    want_to_read = create_hardcover_subscription(@user, kind: "want_to_read")
    list = create_hardcover_subscription(@user, kind: "list")
    own_list = create_hardcover_subscription(@user, kind: "list", target_id: 99)
    own_list.update!(owner_username: "reader#{@user.id}")
    revoke = stub_request(:post, "https://api.hardcover.app/oauth2/revoke").with(body: hash_including("token" => "hc_rt_revoke_me")).to_return(status: 200, body: "{}")

    assert_no_difference -> { Request.count } do
      delete hardcover_connection_path
    end

    assert_requested revoke
    assert_nil @user.reload.hardcover_connection
    assert want_to_read.reload.paused?
    assert list.reload.active?, "other people's public lists can still be read with the instance token"
    assert own_list.reload.paused?, "the user's own lists may be private"
  end

  test "device sign-in honours Hardcover's polling interval" do
    SettingsService.set(:hardcover_oauth_device_flow_enabled, true)
    stub_request(:post, "https://api.hardcover.app/oauth2/device")
      .to_return(status: 200, body: { device_code: "dev-1", user_code: "ABCD-1234", verification_uri: "https://hardcover.app/link", expires_in: 900, interval: 5 }.to_json)
    token = stub_request(:post, TOKEN_URL)
      .to_return(status: 200, body: { access_token: "hc_at_dev", refresh_token: "hc_rt_dev", expires_in: 604_800 }.to_json)
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 4242, "username" => "reader" } ] })

    post device_hardcover_connection_path
    assert_redirected_to device_hardcover_connection_path
    follow_redirect!
    assert_select "p", text: "ABCD-1234"

    post device_poll_hardcover_connection_path(format: :json)
    assert_equal "pending", response.parsed_body["status"]
    assert_not_requested token

    travel 6.seconds do
      post device_poll_hardcover_connection_path(format: :json)
    end
    assert_equal "approved", response.parsed_body["status"]
    assert_requested token, times: 1
    assert_equal 4242, @user.reload.hardcover_connection.hardcover_user_id
  end

  test "sign-in is unavailable until an admin configures a client" do
    SettingsService.set(:hardcover_oauth_client_id, "")

    post authorize_hardcover_connection_path

    assert_redirected_to profile_path
    assert_match(/not configured/, flash[:alert])
  end
end
