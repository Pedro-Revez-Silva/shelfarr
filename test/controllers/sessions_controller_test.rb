require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Password must match the one in fixtures
  FIXTURE_PASSWORD = "Password123!".freeze

  setup do
    @user = users(:one)
    # Ensure user is not locked
    @user.update!(failed_login_count: 0, locked_until: nil)
  end

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { username: @user.username, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create increments failed login count" do
    assert_equal 0, @user.failed_login_count

    post session_path, params: { username: @user.username, password: "wrong" }

    @user.reload
    assert_equal 1, @user.failed_login_count
  end

  test "create shows remaining attempts after failed login" do
    post session_path, params: { username: @user.username, password: "wrong" }

    assert_redirected_to new_session_path
    assert_match(/attempts remaining/, flash[:alert])
  end

  test "create blocks locked account" do
    @user.update!(locked_until: 1.hour.from_now)

    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    assert_redirected_to new_session_path
    assert_match(/Account is locked/, flash[:alert])
    assert_nil cookies[:session_id]
  end

  test "create resets failed logins on success" do
    @user.update!(failed_login_count: 3)

    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    assert_redirected_to root_path
    assert_equal 0, @user.reload.failed_login_count
  end

  test "destroy" do
    sign_in_as(@user)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  test "create with 2FA enabled redirects to OTP verification" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    assert_redirected_to verify_otp_session_path
    assert_nil cookies[:session_id]
    # Session should have pending_user_id set for OTP verification
    assert_equal @user.id, session[:pending_user_id]
  end

  test "submit_otp with valid code completes login" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    # Set up pending session
    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }
    assert_redirected_to verify_otp_session_path

    # Submit valid OTP
    totp = ROTP::TOTP.new(@user.otp_secret)
    post submit_otp_session_path, params: { otp_code: totp.now }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "submit_otp with invalid code shows error" do
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    # Set up pending session
    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    # Submit invalid OTP
    post submit_otp_session_path, params: { otp_code: "000000" }

    assert_redirected_to verify_otp_session_path
    assert_nil cookies[:session_id]
  end
end
