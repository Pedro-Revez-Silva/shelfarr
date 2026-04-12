require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Password must match the one in fixtures
  FIXTURE_PASSWORD = "Password123!".freeze

  setup do
    @user = users(:one)
    # Ensure user is not locked
    @user.update!(failed_login_count: 0, locked_until: nil)
    SettingsService.set(:auth_disabled, false)
    SettingsService.set(:oidc_enabled, false)
    SettingsService.set(:oidc_auto_redirect, false)
    SettingsService.set(:oidc_issuer, "")
    SettingsService.set(:oidc_client_id, "")
    SettingsService.set(:oidc_client_secret, "")
  end

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "new renders OIDC auto handoff when auto redirect is enabled" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")

    get new_session_path

    assert_response :success
    assert_select "h1", /Redirecting to/
    assert_select "form[action='/auth/oidc']"
    assert_select "a[href='#{new_session_path(local: 1)}']", text: /Use local sign-in instead/
    assert_select "input[name='username']", count: 0
  end

  test "new shows local login form when local bypass is requested" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")

    get new_session_path, params: { local: 1 }

    assert_response :success
    assert_select "h1", "Sign in"
    assert_select "div", text: /local login fallback/
    assert_select "input[name='username']"
    assert_select "input[name='password']"
  end

  test "new does not auto redirect when auth is disabled" do
    SettingsService.set(:auth_disabled, true)
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")

    get new_session_path

    assert_response :success
    assert_select "div", text: /Authentication is disabled/
    assert_select "form[action='/auth/oidc']", count: 0
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

  test "destroy redirects to local bypass when OIDC auto redirect is enabled" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")
    sign_in_as(@user)

    delete session_path

    assert_redirected_to new_session_path(local: 1)
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

  # Auth disabled tests
  test "auth disabled: login page shows username-only form" do
    SettingsService.set(:auth_disabled, true)

    get new_session_path

    assert_response :success
    assert_select "input[name='password']", count: 0
    assert_select "input[name='username']"
    assert_select "div", text: /Authentication is disabled/
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: login with username only" do
    SettingsService.set(:auth_disabled, true)

    post session_path, params: { username: @user.username }

    assert_redirected_to root_path
    assert cookies[:session_id]
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: unknown username shows error" do
    SettingsService.set(:auth_disabled, true)

    post session_path, params: { username: "nonexistent" }

    assert_redirected_to new_session_path
    assert_match(/Invalid username/, flash[:alert])
    assert_nil cookies[:session_id]
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: password is not checked" do
    SettingsService.set(:auth_disabled, true)

    post session_path, params: { username: @user.username, password: "totally-wrong" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: 2FA is skipped" do
    SettingsService.set(:auth_disabled, true)
    @user.update!(otp_secret: ROTP::Base32.random, otp_required: true)

    post session_path, params: { username: @user.username }

    assert_redirected_to root_path
    assert cookies[:session_id]
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: locked account is still blocked" do
    SettingsService.set(:auth_disabled, true)
    @user.update!(locked_until: 1.hour.from_now)

    post session_path, params: { username: @user.username }

    assert_redirected_to new_session_path
    assert_match(/Account is locked/, flash[:alert])
    assert_nil cookies[:session_id]
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled: does not track failed logins" do
    SettingsService.set(:auth_disabled, true)

    post session_path, params: { username: "nonexistent" }

    assert_equal 0, @user.reload.failed_login_count
  ensure
    SettingsService.set(:auth_disabled, false)
  end

  test "auth disabled via env var overrides setting" do
    SettingsService.set(:auth_disabled, false)

    ENV["DISABLE_AUTH"] = "true"
    post session_path, params: { username: @user.username }

    assert_redirected_to root_path
    assert cookies[:session_id]
  ensure
    ENV.delete("DISABLE_AUTH")
    SettingsService.set(:auth_disabled, false)
  end

  test "normal login still requires password when auth enabled" do
    SettingsService.set(:auth_disabled, false)

    post session_path, params: { username: @user.username }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create rejects soft-deleted users" do
    @user.update!(deleted_at: Time.current)

    post session_path, params: { username: @user.username, password: FIXTURE_PASSWORD }

    assert_redirected_to new_session_path
    assert_match(/Invalid username or password/, flash[:alert])
    assert_nil cookies[:session_id]
  end
end
