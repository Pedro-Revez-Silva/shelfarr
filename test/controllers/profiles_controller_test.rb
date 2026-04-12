# frozen_string_literal: true

require "test_helper"

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  # Passwords must meet requirements: 12+ chars, uppercase, lowercase, number
  FIXTURE_PASSWORD = "Password123!".freeze
  NEW_VALID_PASSWORD = "NewPassword456!".freeze

  setup do
    @user = users(:one)
    sign_in_as(@user)
    SettingsService.set(:oidc_enabled, false)
    SettingsService.set(:oidc_issuer, "")
    SettingsService.set(:oidc_client_id, "")
    SettingsService.set(:oidc_client_secret, "")
  end

  test "show requires authentication" do
    sign_out
    get profile_path
    assert_response :redirect
  end

  test "show displays user info" do
    get profile_path
    assert_response :success
    assert_select "h1", "My Profile"
    assert_select "h2", @user.name
  end

  test "show displays stats" do
    get profile_path
    assert_response :success
    # Check that stats are displayed (values depend on fixtures)
    assert_select ".bg-gray-800 p.text-2xl"
    assert_select ".bg-green-900\\/30 p.text-2xl"
    assert_select ".bg-yellow-900\\/30 p.text-2xl"
  end

  test "show displays 2FA status" do
    get profile_path
    assert_response :success
    assert_select "dt", "Two-Factor Authentication"
  end

  test "show displays OIDC link button when OIDC is configured and user is not linked" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")

    get profile_path

    assert_response :success
    assert_select "dt", "OIDC Sign-In"
    assert_select "form[action='#{link_oidc_profile_path}']"
    assert_select "button", "Link OIDC Login"
  end

  test "show displays linked OIDC status when account is already linked" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")
    @user.update!(oidc_provider: "oidc", oidc_uid: "linked-uid")

    get profile_path

    assert_response :success
    assert_select "dd", /Linked to/
    assert_select "form[action='#{link_oidc_profile_path}']", count: 0
    assert_select "form[action='#{unlink_oidc_profile_path}']"
  end

  test "edit displays form" do
    get edit_profile_path
    assert_response :success
    assert_select "input[name='user[name]']"
  end

  test "update changes name" do
    patch profile_path, params: { user: { name: "New Name" } }
    assert_redirected_to profile_path
    assert_equal "New Name", @user.reload.name
  end

  test "update rejects blank name" do
    patch profile_path, params: { user: { name: "" } }
    assert_response :unprocessable_entity
    assert_select ".bg-red-500\\/10"
  end

  test "password page displays form" do
    get password_profile_path
    assert_response :success
    assert_select "input[name='current_password']"
    assert_select "input[name='user[password]']"
    assert_select "input[name='user[password_confirmation]']"
  end

  test "update_password requires current password" do
    patch update_password_profile_path, params: {
      current_password: "WrongPassword123!",
      user: { password: NEW_VALID_PASSWORD, password_confirmation: NEW_VALID_PASSWORD }
    }
    assert_response :unprocessable_entity
    assert_select "li", /Current password is incorrect/
  end

  test "update_password changes password" do
    patch update_password_profile_path, params: {
      current_password: FIXTURE_PASSWORD,
      user: { password: NEW_VALID_PASSWORD, password_confirmation: NEW_VALID_PASSWORD }
    }
    assert_redirected_to profile_path
    assert @user.reload.authenticate(NEW_VALID_PASSWORD)
  end

  test "update_password invalidates other sessions" do
    other_session = @user.sessions.create!

    patch update_password_profile_path, params: {
      current_password: FIXTURE_PASSWORD,
      user: { password: NEW_VALID_PASSWORD, password_confirmation: NEW_VALID_PASSWORD }
    }

    assert_redirected_to profile_path
    assert_not Session.exists?(other_session.id)
    assert Session.exists?(Current.session.id)
  end

  test "update_password requires matching confirmation" do
    patch update_password_profile_path, params: {
      current_password: FIXTURE_PASSWORD,
      user: { password: NEW_VALID_PASSWORD, password_confirmation: "Different123!" }
    }
    assert_response :unprocessable_entity
  end

  test "update_password requires minimum length" do
    patch update_password_profile_path, params: {
      current_password: FIXTURE_PASSWORD,
      user: { password: "Short1", password_confirmation: "Short1" }
    }
    assert_response :unprocessable_entity
  end

  test "update_password requires complexity" do
    patch update_password_profile_path, params: {
      current_password: FIXTURE_PASSWORD,
      user: { password: "alllowercase123", password_confirmation: "alllowercase123" }
    }
    assert_response :unprocessable_entity
  end

  test "link_oidc requires configured OIDC" do
    post link_oidc_profile_path

    assert_redirected_to profile_path
    assert_match(/must be fully configured/i, flash[:alert])
  end

  test "link_oidc starts OIDC linking flow for current user" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")

    post link_oidc_profile_path

    assert_response :success
    assert_equal @user.id, session[:pending_oidc_link_user_id]
    assert_select "h1", /Link/
    assert_select "form[action='/auth/oidc']"
    assert_select "a[href='#{profile_path}']", text: "Cancel"
  end

  test "link_oidc returns to profile when account is already linked" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")
    @user.update!(oidc_provider: "oidc", oidc_uid: "linked-uid")

    post link_oidc_profile_path

    assert_redirected_to profile_path
    assert_match(/already linked/i, flash[:notice])
  end

  test "unlink_oidc requires current password when auth is enabled" do
    @user.update!(oidc_provider: "oidc", oidc_uid: "linked-uid")

    delete unlink_oidc_profile_path, params: { current_password: "WrongPassword123!" }

    assert_redirected_to profile_path
    assert_match(/incorrect/i, flash[:alert])
    assert @user.reload.oidc_user?
  end

  test "unlink_oidc removes OIDC link with correct current password" do
    @user.update!(oidc_provider: "oidc", oidc_uid: "linked-uid")

    delete unlink_oidc_profile_path, params: { current_password: FIXTURE_PASSWORD }

    assert_redirected_to profile_path
    assert_match(/removed from your account/i, flash[:notice])
    assert_not @user.reload.oidc_user?
  end

  test "unlink_oidc allows unlinking without password when auth is disabled" do
    SettingsService.set(:auth_disabled, true)
    @user.update!(oidc_provider: "oidc", oidc_uid: "linked-uid")

    delete unlink_oidc_profile_path

    assert_redirected_to profile_path
    assert_not @user.reload.oidc_user?
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  # Two-factor authentication tests
  test "two_factor page displays setup when not enabled" do
    get two_factor_profile_path
    assert_response :success
    assert_select "h3", "Step 1: Scan QR Code"
  end

  test "two_factor page shows enabled status when 2FA active" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    get two_factor_profile_path
    assert_response :success
    assert_select ".bg-green-900\\/30"
  end

  test "enable_two_factor with valid code enables 2FA and shows backup codes" do
    @user.generate_otp_secret!
    totp = ROTP::TOTP.new(@user.otp_secret)

    post enable_two_factor_profile_path, params: { otp_code: totp.now }

    assert_response :success
    assert_select "h1", "Save Your Backup Codes"
    assert @user.reload.otp_enabled?
    assert @user.backup_codes.present?
  end

  test "enable_two_factor with invalid code shows error" do
    @user.generate_otp_secret!

    post enable_two_factor_profile_path, params: { otp_code: "000000" }

    assert_response :unprocessable_entity
    assert_not @user.reload.otp_enabled?
  end

  test "disable_two_factor requires correct password" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    delete disable_two_factor_profile_path, params: { password: "WrongPassword123!" }

    assert_redirected_to two_factor_profile_path
    assert @user.reload.otp_enabled?
  end

  test "disable_two_factor with correct password disables 2FA" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    delete disable_two_factor_profile_path, params: { password: FIXTURE_PASSWORD }

    assert_redirected_to profile_path
    assert_not @user.reload.otp_enabled?
  end
end
