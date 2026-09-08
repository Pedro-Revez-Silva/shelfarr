# frozen_string_literal: true

require "test_helper"

class Auth::OidcMiddlewareTest < ActionDispatch::IntegrationTest
  def app
    @app ||= Rack::URLMap.new("/books" => Rails.application)
  end

  setup do
    OmniAuth.config.test_mode = false
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, false)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")
    SettingsService.set(:oidc_scopes, "openid profile email")
    SettingsService.set(:oidc_auto_create_users, false)
    stub_request(:get, "https://auth.example.com/.well-known/openid-configuration").to_return(
      headers: { "Content-Type" => "application/json" },
      body: {
        issuer: "https://auth.example.com",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token",
        userinfo_endpoint: "https://auth.example.com/userinfo",
        jwks_uri: "https://auth.example.com/jwks",
        response_types_supported: [ "code" ],
        subject_types_supported: [ "public" ],
        id_token_signing_alg_values_supported: [ "HS256" ]
      }.to_json
    )
  end

  test "real request discovery token exchange and callback honor mounted prefix" do
    users(:one).update!(oidc_provider: "oidc", oidc_uid: "mounted-user")
    post "/books/auth/oidc"
    assert_response :redirect
    authorization = URI.parse(response.location)
    assert_equal "auth.example.com", authorization.host
    params = Rack::Utils.parse_query(authorization.query)
    assert_equal "http://www.example.com/books/auth/oidc/callback", params.fetch("redirect_uri")
    token = JSON::JWT.new(
      iss: "https://auth.example.com", sub: "mounted-user", aud: "test-client",
      exp: 5.minutes.from_now.to_i, iat: Time.now.to_i, nonce: params.fetch("nonce")
    ).sign("test-secret", :HS256).to_s
    exchange = stub_request(:post, "https://auth.example.com/token").with(
      body: hash_including("redirect_uri" => params.fetch("redirect_uri"), "code" => "review-code")
    ).to_return(headers: { "Content-Type" => "application/json" }, body: {
      access_token: "review-access-token", token_type: "Bearer", id_token: token
    }.to_json)
    stub_request(:get, "https://auth.example.com/userinfo").to_return(
      headers: { "Content-Type" => "application/json" },
      body: { sub: "mounted-user", email: "review@example.com", name: "Review User" }.to_json
    )
    get "/books/auth/oidc/callback", params: { code: "review-code", state: params.fetch("state") }
    assert_redirected_to "/books/"
    assert_match(/Signed in via/, flash[:notice])
    assert_requested exchange
  end

  test "callback uses the externally forwarded HTTPS origin" do
    post "/books/auth/oidc", headers: {
      "X-Forwarded-Proto" => "https", "X-Forwarded-Host" => "shelf.example.com"
    }

    assert_response :redirect
    params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "https://shelf.example.com/books/auth/oidc/callback", params.fetch("redirect_uri")
  end

  test "provider rejection returns through mounted failure route" do
    post "/books/auth/oidc"
    params = Rack::Utils.parse_query(URI.parse(response.location).query)
    get "/books/auth/oidc/callback", params: { error: "access_denied", state: params.fetch("state") }
    assert_match %r{\A/books/auth/failure\?}, response.location
    follow_redirect!
    assert_redirected_to "/books/session/new"
  end
end
