# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/web_preview_test_helper"
require_relative "../test_helpers/android_updates_test_helper"

class WarmEntryTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include AndroidUpdatesTestHelper

  PASSWORD = "Password123!"
  WARM_CONTROLLERS = %w[sessions registrations consumer/connections android_apps].freeze
  RETIRED_WORDS = /\b(classic|preview|experimental)\b/i

  setup do
    @member = users(:one)
    @admin = users(:two)
    @member.update!(failed_login_count: 0, locked_until: nil)
    SettingsService.set(:auth_disabled, false)
    SettingsService.set(:oidc_enabled, false)
    SettingsService.set(:oidc_auto_redirect, false)
    SettingsService.set(:oidc_issuer, "")
    SettingsService.set(:oidc_client_id, "")
    SettingsService.set(:oidc_client_secret, "")
    setup_android_updates
  end

  teardown { teardown_android_updates }

  def with_warm_entry(&block)
    with_preview_users(@admin, &block)
  end

  def enable_oidc(auto_redirect: false)
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_auto_redirect, auto_redirect)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")
    SettingsService.set(:oidc_provider_name, "Pocket ID")
  end

  def assert_warm_page
    assert_select "body.web-preview.entry-app[data-turbo=false]"
    assert_select "link[rel=stylesheet][href*='web/preview']"
    assert_select "nav[aria-label=Main]", false
    assert_select "main#main .auth-card"
    assert_no_match RETIRED_WORDS, visible_text
  end

  def assert_classic_page
    assert_select "body.entry-app", false
    assert_select "body.bg-gray-950"
  end

  def visible_text
    document = Nokogiri::HTML(response.body)
    document.css("script, style, head").each(&:remove)
    document.at("body").text.squish
  end

  def flash_alert
    css_select("[data-entry-flash=alert][role=alert]").sole.text.squish
  end

  def otp_user
    @member.update!(otp_secret: ROTP::Base32.random, otp_required: true)
    @member
  end

  def pending_grant(requesting: false)
    scope = requesting ? (ConsumerDeviceGrant::SCOPES + ConsumerDeviceGrant::REQUEST_SCOPES) : ConsumerDeviceGrant::SCOPES
    grant, _, code = ConsumerDeviceGrant.issue!(client_name: "Fixture phone", scope: scope.join(" "))
    [ grant, code ]
  end

  test "every template these pages render has a warm version, so the warm layout never wraps an old page" do
    WARM_CONTROLLERS.each do |directory|
      templates = Dir[Rails.root.join("app/views", directory, "*.html.erb")].reject { |path| File.basename(path).start_with?("_") }
      assert_not_empty templates, directory
      templates.each do |path|
        assert File.exist?(path.sub(/\.html\.erb\z/, ".html+warm.erb")), "#{path} has no warm version"
      end
    end
  end

  test "servers without the web preview keep the current pages at the same addresses" do
    get new_session_path
    assert_response :success
    assert_classic_page

    sign_in_as(@member)
    get consumer_connect_path
    assert_classic_page
  end

  def with_precompiled_assets(manifest, files: [])
    Dir.mktmpdir("warm-entry-assets", Rails.root.join("tmp")) do |directory|
      output = Pathname(directory)
      output.join(".manifest.json").write(JSON.generate(manifest))
      files.each { |file| output.join(file).tap { |path| path.dirname.mkpath }.write("") }
      resolver = Propshaft::Resolver::Static.new(manifest_path: output.join(".manifest.json"), prefix: "/assets")
      Rails.application.assets.stub(:resolver, resolver) { yield }
    end
  end

  test "a precompiled server whose web bundle was never built keeps the current sign-in page" do
    with_precompiled_assets({ "tailwind.css" => "tailwind-1.css" }, files: [ "tailwind-1.css" ]) do
      assert_not WarmEntry.stylesheet_built?
    end
  end

  test "a precompiled bundle counts only when its compiled file is there to serve" do
    manifest = { "web/preview.css" => { "digested_path" => "web/preview-1.css", "integrity" => nil } }

    with_precompiled_assets(manifest, files: [ "web/preview-1.css" ]) do
      assert WarmEntry.stylesheet_built?
    end
    with_precompiled_assets(manifest) do
      assert_not WarmEntry.stylesheet_built?
    end
  end

  test "without a servable bundle the current sign-in page renders instead of failing" do
    WarmEntry.stub(:stylesheet_built?, false) do
      with_warm_entry { get new_session_path }
    end

    assert_response :success
    assert_classic_page
    assert_select "input[name=password]"
  end

  test "a frame request with the preview off keeps the frame layout it had" do
    get new_session_path, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "body.bg-gray-950", false
    assert_select "nav[aria-label=Main]", false
    assert_select "input[name=password]"
  end

  test "the warm sign-in page still ends a session the server has expired" do
    sign_in_as(@member)
    expired = Current.session
    expired.update!(created_at: 2.days.ago)
    SettingsService.set(:session_max_age_days, 1)

    with_warm_entry { get new_session_path }

    assert_response :success
    assert_warm_page
    assert_not Session.exists?(expired.id)
    assert_empty cookies[:session_id].to_s
    assert_select "[data-entry-account]", false
  ensure
    SettingsService.set(:session_max_age_days, 30)
  end

  test "a signed-in visitor sees which account the entry page acts for" do
    sign_in_as(@member)

    with_warm_entry { get consumer_connect_path }

    assert_select "[data-entry-account]", "Signed in as #{@member.name}"
  end

  test "password sign-in posts to the same session endpoint with a CSRF token and returns to the page that asked" do
    with_warm_entry do
      with_forgery_protection do
        get consumer_connect_path(user_code: "ABCD-EFGH")
        assert_redirected_to new_session_path
        follow_redirect!

        assert_response :success
        assert_warm_page
        assert_select "title", "Sign in · Shelfarr"
        assert_select "h1", "Sign in"
        assert_select "[data-controller=consumer-offline-signed-out]"
        form = css_select("form.auth-form[method=post]").sole
        assert_equal session_url, form["action"]
        token = form.at_css("input[name=authenticity_token]")["value"]
        assert form.at_css("input[name=username][autocomplete=username][required]")
        assert form.at_css("input[name=password][type=password][autocomplete=current-password][maxlength='72'][required]")
        assert_select "form[action='/auth/oidc']", false

        post session_path, params: { username: @member.username, password: PASSWORD }
        assert_response :unprocessable_entity
        assert_nil cookies[:session_id].presence

        post session_path, params: { authenticity_token: token, username: @member.username, password: PASSWORD }
        assert_redirected_to consumer_connect_url(user_code: "ABCD-EFGH")
        follow_redirect!
        assert_warm_page
        assert_select "input[name=user_code][value='ABCD-EFGH']"
      end
    end
  end

  test "a wrong password, a locked account and an unknown user each explain themselves on the warm page" do
    with_warm_entry do
      post session_path, params: { username: @member.username, password: "wrong" }
      assert_redirected_to new_session_path
      follow_redirect!
      assert_warm_page
      assert_equal "Invalid username or password. 4 attempts remaining.", flash_alert

      post session_path, params: { username: "nobody", password: "wrong" }
      follow_redirect!
      assert_equal "Invalid username or password.", flash_alert

      @member.update!(locked_until: 10.minutes.from_now)
      post session_path, params: { username: @member.username, password: PASSWORD }
      follow_redirect!
      assert_match(/\AAccount is locked\. Try again in/, flash_alert)
      assert_nil cookies[:session_id].presence
    end
  end

  test "two-step verification takes the code, rejects a wrong one and accepts a backup code" do
    user = otp_user
    backup = user.generate_backup_codes!.first

    with_warm_entry do
      post session_path, params: { username: user.username, password: PASSWORD }
      assert_redirected_to verify_otp_session_path
      follow_redirect!

      assert_warm_page
      assert_select "h1", "Two-step verification"
      assert_select "form[action='#{submit_otp_session_path}'][method=post] input[name=otp_code][autocomplete=one-time-code][maxlength='8']"
      assert_select "a[href='#{new_session_path}']", "Cancel and sign in again"

      post submit_otp_session_path, params: { otp_code: "000000" }
      assert_redirected_to verify_otp_session_path
      follow_redirect!
      assert_equal "Invalid verification code. Please try again.", flash_alert
      assert_nil cookies[:session_id].presence

      post submit_otp_session_path, params: { otp_code: backup.downcase }
      assert_redirected_to root_path
      assert cookies[:session_id].present?
    end
  end

  test "the code page without a pending sign-in goes back to sign in" do
    with_warm_entry { get verify_otp_session_path }

    assert_redirected_to new_session_path
  end

  test "single sign-on offers its button beside the password form" do
    enable_oidc

    with_warm_entry { get new_session_path }

    assert_warm_page
    assert_select "form.entry-sso-form[action='/auth/oidc'][method=post] button", /Sign in with Pocket ID/
    assert_select "form.auth-form input[name=password]"
    assert_equal "same-origin", response.headers["Referrer-Policy"]
  end

  test "single sign-on auto-redirect hands off, and its local fallback and failures land on the warm form" do
    enable_oidc(auto_redirect: true)

    with_warm_entry do
      get new_session_path
      assert_warm_page
      assert_select "h1", "Redirecting to Pocket ID"
      assert_select "[data-controller=oidc-redirect] form[action='/auth/oidc'][method=post][data-oidc-redirect-target=form]"
      assert_select "a[href=?]", new_session_path(local: 1), text: "use local sign-in instead"
      assert_select "input[name=username]", false

      get "/auth/failure", params: { message: "invalid_credentials" }
      assert_redirected_to new_session_path(local: 1)
      follow_redirect!
      assert_warm_page
      assert_select "h1", "Sign in"
      assert_equal "SSO authentication failed: invalid_credentials", flash_alert
      assert_select "[data-entry-local-fallback]", /normally signs you in with Pocket ID/
      assert_select "input[name=password]"
    end
  end

  test "sign-in off asks for the username only and still refuses a locked account" do
    SettingsService.set(:auth_disabled, true)
    enable_oidc(auto_redirect: true)

    with_warm_entry do
      get new_session_path
      assert_warm_page
      assert_select "[data-entry-auth-off]"
      assert_select "form.auth-form input[name=username]"
      assert_select "input[name=password]", false
      assert_select "form[action='/auth/oidc']", false

      @member.update!(locked_until: 10.minutes.from_now)
      post session_path, params: { username: @member.username }
      follow_redirect!
      assert_match(/\AAccount is locked/, flash_alert)
    end
  end

  test "the first account is created on the warm page and goes on to server setup" do
    User.find_each(&:destroy!)

    with_warm_entry do
      get new_session_path
      assert_redirected_to sign_up_path
      follow_redirect!
      assert_warm_page
      assert_select "h1", "Create your account"
      assert_select "form[action='#{sign_up_path}'][method=post]" do
        %w[name username password password_confirmation].each { |field| assert_select "input[name='user[#{field}]']" }
        assert_select "select", false
      end

      post sign_up_path, params: { user: { name: "First", username: "first", password: "short", password_confirmation: "short" } }
      assert_response :unprocessable_entity
      assert_warm_page
      assert_select "[data-entry-errors][role=alert] li", minimum: 1
      assert_select "input[name='user[password]'][aria-invalid=true]"
      assert_equal 0, User.count

      post sign_up_path, params: { user: { name: "First", username: "first", password: PASSWORD, password_confirmation: PASSWORD } }
      assert_redirected_to admin_setup_wizard_path
      assert User.find_by!(username: "first").admin?
      assert cookies[:session_id].present?
    end
  end

  test "an administrator adding people keeps the people form, which the server settings work replaces" do
    sign_in_as(@admin)

    with_warm_entry { get sign_up_path }

    assert_response :success
    assert_classic_page
    assert_select "select[name='user[role]']"
  end

  test "sign-up stays closed to visitors once an account exists" do
    with_warm_entry do
      get sign_up_path
      assert_redirected_to root_path

      sign_in_as(@member)
      get sign_up_path
      assert_redirected_to root_path
    end
  end

  test "the phone-app code page asks for the code, says when it is unknown and approves with the CSRF token" do
    grant, code = pending_grant(requesting: true)
    sign_in_as(@member)

    with_warm_entry do
      with_forgery_protection do
        get consumer_connect_path
        assert_warm_page
        assert_select "form[action='#{consumer_connect_path}'][method=get] input[name=user_code][maxlength='32']"
        assert_select "[data-consumer-approval=unknown-code]", false
        assert_equal "private, no-store", response.headers["Cache-Control"]

        get consumer_connect_path(user_code: "ZZZZ-ZZZZ")
        assert_select "[data-consumer-approval=unknown-code][role=alert]"

        get consumer_connect_path(user_code: code)
        assert_warm_page
        assert_select "h1", "Connect your Shelfarr app"
        assert_select ".user-code", code.upcase
        assert_select "[data-consumer-approval=requesting]"
        form = css_select("form[action='#{consumer_connect_path}'][method=post]").sole
        assert_equal code, form.at_css("input[name=user_code]")["value"]
        assert_equal %w[allow deny], form.css("button[name=decision]").map { |button| button["value"] }
        token = form.at_css("input[name=authenticity_token]")["value"]

        post consumer_connect_path, params: { authenticity_token: token, user_code: code, decision: "allow" }
        assert_response :success
        assert_warm_page
        assert_select "h1", "App connected"
        assert_select "a[href='#{profile_path}']", "manage connected apps in Account"
        assert grant.reload.approved_at
        assert_equal @member, grant.user
      end
    end
  end

  test "denying, a used code and another account's app are all answered on warm pages" do
    sign_in_as(@member)

    with_warm_entry do
      _, code = pending_grant
      post consumer_connect_path, params: { user_code: code, decision: "deny" }
      assert_response :success
      assert_select "h1", "Connection denied"

      post consumer_connect_path, params: { user_code: code, decision: "allow" }
      assert_response :unprocessable_entity
      assert_warm_page
      assert_match(/expired or has already been used/, flash_alert)

      token, = APIToken.issue!(name: "Admin phone", user: @admin, scopes: ConsumerDeviceGrant::SCOPES, issued_via: APIToken::CONSUMER_DEVICE)
      grant, _, foreign = ConsumerDeviceGrant.issue!(client_name: "Admin phone",
        scope: (ConsumerDeviceGrant::SCOPES + ConsumerDeviceGrant::REQUEST_SCOPES).join(" "), replaces: token)
      get consumer_connect_path(user_code: foreign)
      assert_select "[data-consumer-approval=wrong-account]"
      assert_select "form[action='#{session_path}'] input[name=_method][value=delete]"

      post consumer_connect_path, params: { user_code: foreign, decision: "allow" }
      assert_response :forbidden
      assert_warm_page
      assert_equal "This app is connected to a different Shelfarr account. Nothing was changed.", flash_alert
      assert_not grant.reload.approved_at

      post consumer_connect_path, params: { user_code: foreign, decision: "maybe" }
      assert_response :bad_request
    end
  end

  test "the Android page is public and warm, and only administrators see why a build is missing" do
    https!
    android_store.write_status("checked_at" => "2026-11-08T10:00:00Z", "channels" => { "release" => { "error" => "catalog_network" } })

    with_warm_entry do
      get android_app_path
      assert_response :ok
      assert_warm_page
      assert_select "title", "Shelfarr for Android · Shelfarr"
      assert_select "[role=status]", /isn't ready on this server yet/
      assert_select "[data-android-admin-note]", false
      assert_equal "no-store", response.headers["Cache-Control"]

      sign_in_as(@member)
      get android_app_path
      assert_select "[data-android-admin-note]", false
      assert_not_includes response.body, "catalog_network"
      sign_out

      sign_in_as(@admin)
      get android_app_path
      assert_select "[data-android-admin-note]", /catalog_network/

      get android_app_path, params: { channel: "development" }
      assert_response :not_found
      assert_warm_page
      assert_select "[role=status]", /doesn't offer the development Android build/
    end
  end

  test "the Android page offers the download and the connect link under a subpath" do
    https!
    host! "books.example.org:8443"
    release = promote_fixture(fake_apk("warm"), version_code: 34)

    with_warm_entry { get android_app_path, env: { "SCRIPT_NAME" => "/shelfarr" } }

    assert_warm_page
    assert_select "#android-download[href=?]", "/shelfarr/apps/android/release/#{release.file_name}", text: "Download Shelfarr 2026.11.34"
    assert_select "#android-open[href=?]", "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%3A8443%2Fshelfarr", text: "Open Shelfarr"
    assert_select "a.wordmark[href='/shelfarr/']"
  end
end

class WarmEntrySubpathTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  BASE = "/shelf"

  setup do
    @previous_root = ActionController::Base.relative_url_root
    ActionController::Base.relative_url_root = BASE
  end

  teardown { ActionController::Base.relative_url_root = @previous_root }

  def app
    @app ||= Rack::URLMap.new(BASE => Rails.application)
  end

  test "sign-in, its assets and its form all live under the deployment path" do
    with_preview_users(users(:two)) do
      get "#{BASE}/preview/library"
      assert_redirected_to "http://www.example.com#{BASE}/session/new"
      follow_redirect!
    end

    assert_response :success
    assert_select "body.entry-app"
    assert_select "link[rel=stylesheet][href^='#{BASE}/assets/web/preview-']"
    assert_select "form.auth-form[action='http://www.example.com#{BASE}/session']"
    assert_select "[data-consumer-offline-signed-out-base-value='#{BASE}']"
    assert_select "a.wordmark[href='#{BASE}/']"
  end
end
