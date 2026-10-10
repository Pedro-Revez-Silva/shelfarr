# frozen_string_literal: true

require "test_helper"

class Hardcover::CredentialsTest < ActiveSupport::TestCase
  TOKEN_URL = "https://api.hardcover.app/oauth2/token"

  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 404)
    @user = users(:one)
  end

  test "an expiring OAuth token is refreshed before use" do
    connection = create_hardcover_connection(@user, access_token: "hc_at_old", refresh_token: "hc_rt_old", expires_at: 1.minute.from_now)
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "hc_at_new", refresh_token: "hc_rt_new", expires_in: 604_800 }.to_json)
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 4242 } ] })

    Hardcover::Credentials.with_connection(connection) { |credential| HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }

    assert_equal "Bearer hc_at_new", hardcover_requests.last[:authorization]
    assert_equal "hc_rt_new", connection.reload.refresh_token
  end

  test "a token Hardcover revoked early is refreshed once and the call retried" do
    connection = create_hardcover_connection(@user, access_token: "hc_at_revoked", refresh_token: "hc_rt_ok")
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: "hc_at_fresh", refresh_token: "hc_rt_fresh", expires_in: 604_800 }.to_json)
    stub_request(:post, HardcoverClient::BASE_URL).with(headers: { "Authorization" => "Bearer hc_at_revoked" }).to_return(status: 401, body: "{}")
    stub_request(:post, HardcoverClient::BASE_URL).with(headers: { "Authorization" => "Bearer hc_at_fresh" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: { me: [ { id: 4242 } ] } }.to_json)

    result = Hardcover::Credentials.with_connection(connection) { |credential| HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }

    assert_equal 4242, result.dig("data", "me", 0, "id")
    assert connection.reload.active?
  end

  test "a refused refresh requires reconnecting and pauses Want to Read automation" do
    connection = create_hardcover_connection(@user, expires_at: 1.minute.ago)
    subscription = create_hardcover_subscription(@user, kind: "want_to_read")
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    assert_raises(HardcoverClient::AuthenticationError) do
      Hardcover::Credentials.with_connection(connection) { flunk "must not query with an expired token" }
    end

    assert_equal "reauthorization_required", connection.reload.status
    assert subscription.reload.paused?
  end

  test "a rejected personal key requires reconnecting" do
    connection = create_hardcover_connection(@user, auth_method: "personal_token", access_token: "hc_pat")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 401, body: "{}")

    assert_raises(HardcoverClient::AuthenticationError) do
      Hardcover::Credentials.with_connection(connection) { |credential| HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    end
    assert_not connection.reload.active?
  end

  test "a missing scope does not disconnect the account" do
    connection = create_hardcover_connection(@user)
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 403, headers: { "Content-Type" => "application/json" },
      body: { error: "insufficient_scope", scope: "read:lists" }.to_json)

    assert_raises(HardcoverClient::ScopeError) do
      Hardcover::Credentials.with_connection(connection) { |credential| HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    end
    assert connection.reload.active?
  end

  test "catalog reads prefer the instance token and fall back to the user's connection" do
    create_hardcover_connection(@user)
    SettingsService.set(:hardcover_api_token, "")
    assert Hardcover::Credentials.catalog_available?(user: @user)
    assert_not Hardcover::Credentials.catalog_available?(user: users(:two))

    used = Hardcover::Credentials.with_catalog(user: @user) { |credential| credential.authorization_header }
    assert_equal "Bearer hc_at_test_#{@user.id}", used

    configure_hardcover_instance_token("instance")
    used = Hardcover::Credentials.with_catalog(user: @user) { |credential| credential.authorization_header }
    assert_equal "Bearer instance", used
  end

  test "a disabled provider makes connections unusable" do
    connection = create_hardcover_connection(@user)
    SettingsService.set(:hardcover_enabled, false)

    assert_raises(Hardcover::Credentials::Unavailable) { Hardcover::Credentials.with_connection(connection) { flunk } }
  end
end
