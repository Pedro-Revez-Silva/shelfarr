# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/web_preview_test_helper"

class OfflineContinuityTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  PASSWORD = "Password123!"
  NAME = OfflineContinuity.cookie_name("/preview")

  setup do
    [ users(:one), users(:two) ].each { |user| user.update!(failed_login_count: 0, locked_until: nil) }
    SettingsService.set(:auth_disabled, false)
    SettingsService.set(:oidc_enabled, false)
    SettingsService.set(:oidc_auto_redirect, false)
    OmniAuth.config.test_mode = true
    OmniAuth.config.silence_get_warning = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:oidc] = nil
  end

  def continuity_cookies
    Array(response.headers["Set-Cookie"]).flat_map { |header| header.split("\n") }.select { |line| line.start_with?("#{NAME}=") }
  end

  def issued_marker
    line = continuity_cookies.sole
    attributes = line.split(";").map(&:strip)
    assert_includes attributes, "path=/preview"
    assert_includes attributes, "samesite=lax"
    assert_not attributes.any? { |attribute| attribute.casecmp?("httponly") }
    assert attributes.any? { |attribute| attribute.start_with?("expires=") }
    value = attributes.first.delete_prefix("#{NAME}=")
    assert_match(/\A[A-Za-z0-9]{24}\z/, value)
    value
  end

  def sign_in_locally(user)
    post session_path, params: { username: user.username, password: PASSWORD }
    assert_response :redirect
    issued_marker
  end

  def enable_oidc
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "client-id")
    SettingsService.set(:oidc_client_secret, "client-secret")
    SettingsService.set(:oidc_auto_create_users, false)
  end

  def provider_answers_for(user, uid)
    user.update!(oidc_provider: "oidc", oidc_uid: uid)
    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new(provider: "oidc", uid: uid, info: { email: "#{uid}@example.test", name: user.name })
  end

  def bootstrap_marker
    get web_preview_api_auth_bootstrap_path
    assert_response :success
    response.parsed_body.fetch("offline_continuity")
  end

  { "classic" => false, "warm" => true }.each do |variant, warm|
    test "every #{variant} local sign-in and sign-out gives this deployment a new offline marker before any page script runs" do
      with_env(WebPreview::Access::VARIABLE => warm ? [ users(:one), users(:two) ].map(&:id).join(",") : nil) do
        get new_session_path
        assert_response :success
        assert_select "body.entry-app", count: warm ? 1 : 0
        assert_empty continuity_cookies

        first = sign_in_locally(users(:one))
        delete session_path
        signed_out = issued_marker
        second = sign_in_locally(users(:two))
        again = sign_in_locally(users(:one))
        assert_equal 4, [ first, signed_out, second, again ].uniq.size
      end
    end
  end

  test "the bootstrap reports the marker the request carried and never issues one, so a late answer cannot replace a newer marker" do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      get web_preview_api_auth_bootstrap_path
      assert_response :success
      assert_not response.parsed_body.key?("offline_continuity")
      assert_empty continuity_cookies

      cookies[NAME] = "carriedFromTheRequest"
      assert_equal "carriedFromTheRequest", bootstrap_marker
      assert_empty continuity_cookies
    end
  end

  test "a browser without a session gets a new marker from every preview answer, page or API" do
    with_preview_users(users(:one)) do
      get web_preview_api_auth_bootstrap_path
      assert_equal false, response.parsed_body.fetch("authenticated")
      first = issued_marker
      get web_preview_downloads_path
      assert_redirected_to new_session_path
      assert_not_equal first, issued_marker
    end
  end

  test "with the preview switched off, every preview answer is a refusal that rotates the marker" do
    with_env(WebPreview::Access::VARIABLE => nil) do
      sign_in_as(users(:one))
      get web_preview_downloads_path
      assert_response :not_found
      first = issued_marker
      get web_preview_api_auth_bootstrap_path
      assert_response :not_found
      assert_not_equal first, issued_marker
    end
  end

  test "signing in a second time with two-step verification still rotates the marker once the code is accepted" do
    user = users(:one)
    user.update!(otp_secret: ROTP::Base32.random, otp_required: true)
    post session_path, params: { username: user.username, password: PASSWORD }
    assert_redirected_to verify_otp_session_path
    assert_empty continuity_cookies
    post submit_otp_session_path, params: { otp_code: ROTP::TOTP.new(user.otp_secret).now }
    assert_redirected_to root_path
    issued_marker
  end

  test "single sign-on rotates the marker when it signs someone in, and linking an identity leaves it alone" do
    enable_oidc
    provider_answers_for(users(:one), "one-uid")
    get "/auth/oidc/callback"
    assert_redirected_to root_path
    signed_in = issued_marker

    users(:one).update!(oidc_provider: nil, oidc_uid: nil)
    post link_oidc_profile_path
    assert_response :success
    assert_empty continuity_cookies
    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new(provider: "oidc", uid: "linked-uid", info: { email: "linked@example.test", name: "Linked" })
    get "/auth/oidc/callback"
    assert_redirected_to profile_path
    assert_equal "linked-uid", users(:one).reload.oidc_uid
    assert_empty continuity_cookies

    provider_answers_for(users(:two), "two-uid")
    get "/auth/oidc/callback"
    assert_redirected_to root_path
    assert_not_equal signed_in, issued_marker
  end

  test "single sign-on that is refused or fails changes nothing" do
    enable_oidc
    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new(provider: "oidc", uid: "nobody", info: { email: "nobody@example.test" })
    get "/auth/oidc/callback"
    assert_response :redirect
    assert_empty continuity_cookies
    get "/auth/failure", params: { message: "access_denied" }
    assert_empty continuity_cookies
  end

  test "a failed password sign-in leaves the current marker alone" do
    post session_path, params: { username: users(:one).username, password: "wrong" }
    assert_redirected_to new_session_path
    assert_empty continuity_cookies
  end

  test "creating the first account signs it in with a new marker" do
    User.update_all(deleted_at: Time.current)
    post sign_up_path, params: { user: { name: "First", username: "first_owner", password: PASSWORD, password_confirmation: PASSWORD } }
    assert_response :redirect
    issued_marker
  end

  test "a session that ended on the server rotates the marker the next time the browser shows up" do
    sign_in_as(users(:one))
    Session.where(user: users(:one)).update_all(created_at: 31.days.ago)
    get root_path
    assert_redirected_to new_session_path
    issued_marker

    sign_in_as(users(:one))
    Session.where(user: users(:one)).delete_all
    get root_path
    assert_redirected_to new_session_path
    issued_marker
  end

  test "an account the allowlist no longer names gets a new marker with every refusal, page or API" do
    with_preview_users(users(:two)) do
      sign_in_as(users(:one))
      get web_preview_downloads_path
      assert_response :not_found
      first = issued_marker
      get web_preview_api_auth_bootstrap_path
      assert_response :not_found
      assert_not_equal first, issued_marker
    end
  end

  test "an account taken off the allowlist while its request is being created is refused with a new marker" do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      removed_meanwhile = lambda do |*|
        ENV[WebPreview::Access::VARIABLE] = users(:two).id.to_s
        { title: "Middlemarch", author: "George Eliot" }
      end
      BookMetadataLookupService.stub(:call, removed_meanwhile) do
        post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "ebook", language: "en" },
          headers: account_headers(users(:one)), as: :json
      end
      assert_response :not_found
      assert_equal({ "error" => "not_found" }, response.parsed_body)
      issued_marker
    end
  end

  test "a session ended while its request is being created is answered signed out with a new marker" do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      session = Current.session
      ending = lambda do |*|
        session.destroy!
        { title: "Middlemarch", author: "George Eliot" }
      end
      BookMetadataLookupService.stub(:call, ending) do
        post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "ebook", language: "en" },
          headers: account_headers(users(:one)), as: :json
      end
      assert_equal [ 401, { "error" => "signed_out" } ], [ response.status, response.parsed_body ]
      issued_marker
    end
  end

  test "accepting the account keeps the marker untouched on ordinary preview requests" do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      cookies[NAME] = "steady"
      get web_preview_downloads_path
      assert_response :success
      get web_preview_api_session_path, headers: account_headers(users(:one))
      assert_response :success
      assert_empty continuity_cookies
    end
  end
end
