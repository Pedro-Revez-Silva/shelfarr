# frozen_string_literal: true

require "test_helper"

class Auth::OmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.silence_get_warning = true

    # Enable OIDC settings
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")
    SettingsService.set(:oidc_auto_create_users, false)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:oidc] = nil
  end

  test "successful OIDC login with existing user" do
    user = users(:one)
    user.update!(oidc_provider: "oidc", oidc_uid: "12345")

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "12345",
      info: {
        email: "test@example.com",
        name: "Test User"
      }
    })

    get "/auth/oidc/callback"

    assert_redirected_to root_path
    assert_match(/Signed in via/, flash[:notice])
  end

  test "OIDC login fails when user not found and auto-create disabled" do
    SettingsService.set(:oidc_auto_create_users, false)

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "unknown-uid",
      info: {
        email: "newuser@example.com",
        name: "New User"
      }
    })

    get "/auth/oidc/callback"

    assert_redirected_to new_session_path
    assert_match(/not found/i, flash[:alert])
  end

  test "OIDC login creates user when auto-create enabled" do
    SettingsService.set(:oidc_auto_create_users, true)
    SettingsService.set(:oidc_default_role, "user")

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "new-user-uid",
      info: {
        email: "newuser@example.com",
        name: "New User From OIDC"
      }
    })

    assert_difference("User.count", 1) do
      get "/auth/oidc/callback"
    end

    assert_redirected_to root_path

    new_user = User.find_by(oidc_uid: "new-user-uid")
    assert_not_nil new_user
    assert_equal "newuser", new_user.username
    assert_equal "New User From OIDC", new_user.name
    assert_equal "user", new_user.role
    assert_equal "oidc", new_user.oidc_provider
  end

  test "OIDC login creates admin when default role is admin" do
    SettingsService.set(:oidc_auto_create_users, true)
    SettingsService.set(:oidc_default_role, "admin")

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "admin-user-uid",
      info: {
        email: "adminuser@example.com",
        name: "Admin User"
      }
    })

    assert_difference("User.count", 1) do
      get "/auth/oidc/callback"
    end

    new_user = User.find_by(oidc_uid: "admin-user-uid")
    assert_equal "admin", new_user.role
  end

  test "OIDC login fails for locked user" do
    user = users(:one)
    user.update!(
      oidc_provider: "oidc",
      oidc_uid: "locked-user-uid",
      locked_until: 1.hour.from_now
    )

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "locked-user-uid",
      info: { email: "test@example.com" }
    })

    get "/auth/oidc/callback"

    assert_redirected_to new_session_path
    assert_match(/locked/i, flash[:alert])
  end

  test "failure endpoint handles OIDC errors" do
    get "/auth/failure", params: { message: "invalid_credentials" }

    assert_redirected_to new_session_path
    assert_match(/invalid_credentials/i, flash[:alert])
  end

  test "OIDC callback without auth hash redirects with error" do
    # Clear any mock auth to simulate missing data
    OmniAuth.config.mock_auth[:oidc] = :invalid_credentials

    get "/auth/oidc/callback"

    # OmniAuth will redirect to failure endpoint first
    assert_response :redirect
    follow_redirect!

    # Then our failure handler redirects to login
    assert_redirected_to new_session_path
  end
end
