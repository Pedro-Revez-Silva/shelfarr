# frozen_string_literal: true

require "test_helper"

class Auth::OidcRelativeUrlRootTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.silence_get_warning = true

    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, false)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")
    SettingsService.set(:oidc_auto_create_users, false)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:oidc] = nil
  end

  # Mirror config.ru: RAILS_RELATIVE_URL_ROOT mounts the app under a prefix.
  def app
    @app ||= Rack::URLMap.new("/books" => Rails.application)
  end

  test "OIDC login form posts to the mounted auth path" do
    get "/books/session/new"

    assert_response :success
    assert_select "form[action='/books/auth/oidc'][method='post']"
    assert_select "form[action='/auth/oidc']", count: 0
  end

  test "OIDC auto-redirect handoff posts to the mounted auth path" do
    SettingsService.set(:oidc_auto_redirect, true)

    get "/books/session/new"

    assert_response :success
    assert_select "h1", /Redirecting to/
    assert_select "form[action='/books/auth/oidc'][method='post']"
    assert_select "form[action='/auth/oidc']", count: 0
  end

  test "OIDC account-link handoff posts to the mounted auth path" do
    sign_in_as(users(:one))

    post "/books/profile/link_oidc"

    assert_response :success
    assert_select "form[action='/books/auth/oidc'][method='post']"
    assert_select "form[action='/auth/oidc']", count: 0
  end

  test "OIDC callback succeeds under the relative url root" do
    user = users(:one)
    user.update!(oidc_provider: "oidc", oidc_uid: "rel-root-uid")

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "rel-root-uid",
      info: {
        email: "test@example.com",
        name: "Test User"
      }
    })

    get "/books/auth/oidc/callback"

    assert_redirected_to root_path(script_name: "/books")
    assert_match(/Signed in via/, flash[:notice])
  end

  test "OIDC routes without the relative url root are not found" do
    get "/auth/oidc/callback"

    assert_response :not_found
  end
end
