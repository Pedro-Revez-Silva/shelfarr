# frozen_string_literal: true

require "test_helper"

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  # Passwords must meet requirements: 12+ chars, uppercase, lowercase, number
  FIXTURE_PASSWORD = "Password123!".freeze
  NEW_VALID_PASSWORD = "NewPassword456!".freeze

  setup do
    @user = users(:one)
    sign_in_as(@user)
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
    assert_select ".bg-gray-50 p.text-2xl"
    assert_select ".bg-green-50 p.text-2xl"
    assert_select ".bg-yellow-50 p.text-2xl"
  end

  test "show displays 2FA status" do
    get profile_path
    assert_response :success
    assert_select "dt", "Two-Factor Authentication"
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
    assert_select ".bg-red-50"
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
    assert_select ".bg-green-50"
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
