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

  test "OIDC login links existing local user when linking is enabled" do
    SettingsService.set(:oidc_link_existing_users, true)

    user = User.create!(
      username: "existing_user",
      name: "Existing User",
      password: "ValidPassword123!"
    )

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "existing-user-uid",
      info: {
        preferred_username: "existing_user",
        email: "existing_user@example.com",
        name: "Existing User"
      }
    })

    get "/auth/oidc/callback"

    assert_redirected_to root_path
    assert_equal "oidc", user.reload.oidc_provider
    assert_equal "existing-user-uid", user.oidc_uid
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

  test "OIDC callback links current signed-in user when link flow is pending" do
    user = users(:one)
    sign_in_as(user)
    post link_oidc_profile_path
    assert_equal user.id, session[:pending_oidc_link_user_id]

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "linked-user-uid",
      info: {
        email: "test@example.com",
        name: "Linked User"
      }
    })

    get "/auth/oidc/callback"

    assert_redirected_to profile_path
    assert_match(/now linked/i, flash[:notice])
    assert_equal "oidc", user.reload.oidc_provider
    assert_equal "linked-user-uid", user.oidc_uid
    assert_nil session[:pending_oidc_link_user_id]
  end

  test "OIDC callback refuses to link identity that belongs to another user" do
    user = users(:one)
    other_user = users(:two)
    other_user.update!(oidc_provider: "oidc", oidc_uid: "shared-uid")

    sign_in_as(user)
    post link_oidc_profile_path

    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new({
      provider: "oidc",
      uid: "shared-uid",
      info: {
        email: "admin@example.com",
        name: "Existing OIDC User"
      }
    })

    get "/auth/oidc/callback"

    assert_redirected_to profile_path
    assert_match(/already linked to another/i, flash[:alert])
    assert_nil user.reload.oidc_uid
  end

  test "failure endpoint handles OIDC errors" do
    get "/auth/failure", params: { message: "invalid_credentials" }

    assert_redirected_to new_session_path
    assert_match(/invalid_credentials/i, flash[:alert])
  end

  test "failure endpoint redirects to local bypass when OIDC auto redirect is enabled" do
    SettingsService.set(:oidc_auto_redirect, true)

    get "/auth/failure", params: { message: "invalid_credentials" }

    assert_redirected_to new_session_path(local: 1)
    assert_match(/invalid_credentials/i, flash[:alert])
  end

  test "failure endpoint returns to profile when OIDC link flow is pending" do
    user = users(:one)
    sign_in_as(user)
    post link_oidc_profile_path

    get "/auth/failure", params: { message: "invalid_credentials" }

    assert_redirected_to profile_path
    assert_match(/invalid_credentials/i, flash[:alert])
    assert_nil session[:pending_oidc_link_user_id]
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

  test "OIDC callback user-not-found failure redirects to local bypass when auto redirect is enabled" do
    SettingsService.set(:oidc_auto_redirect, true)
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

    assert_redirected_to new_session_path(local: 1)
    assert_match(/not found/i, flash[:alert])
  end
end
