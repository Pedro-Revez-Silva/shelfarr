# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AccountTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  PASSWORD = "Password123!"

  setup do
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = users(:one)
    @admin = users(:two)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def account(user)
    preview_get web_preview_api_account_path, user: user
    assert_response :success
    response.parsed_body
  end

  def send_json(method, path, user:, **body)
    public_send(method, path, params: body, headers: account_headers(user), as: :json)
    response.parsed_body
  end

  test "a member reads their own profile and personal settings, and never server settings or another account" do
    token, = APIToken.issue!(name: "Phone", user: @member, scopes: %w[library:read])
    APIToken.issue!(name: "Someone else's", user: @admin, scopes: %w[library:read])
    sign_in_as(@member)
    body = account(@member)
    assert_equal @member.id.to_s, body.fetch("account")
    profile = body.fetch("profile")
    assert_equal [ @member.id.to_s, "userone", "User One" ], profile.values_at("id", "username", "name")
    settings = profile.fetch("settings")
    assert_not settings.fetch("admin")
    assert_equal({ "enabled" => false }, settings.fetch("two_factor"))
    assert_equal [ token.id.to_s ], settings.fetch("api_tokens").map { |entry| entry.fetch("id") }
    assert_equal %w[id name prefix scopes app state created_at last_used_at expires_at], settings.fetch("api_tokens").sole.keys
    assert_equal APIToken::SELF_SERVICE_SCOPES, settings.fetch("token_scopes").map { |entry| entry.fetch("scope") }
    assert_not settings.fetch("links").key?("admin")
    assert_not_includes response.body, "token_digest"
  end

  test "a member renames themselves, and a blank name is refused with its field" do
    sign_in_as(@member)
    assert_equal "Reader One", send_json(:put, web_preview_api_account_profile_path, user: @member, name: "Reader One").dig("profile", "name")
    body = send_json(:put, web_preview_api_account_profile_path, user: @member, name: " ")
    assert_response :unprocessable_entity
    assert_equal({ "account" => @member.id.to_s, "error" => "invalid_profile", "errors" => { "name" => [ "can't be blank" ] } }, body)
    assert_equal "Reader One", @member.reload.name
  end

  test "changing the password needs the current one and signs out every other browser but this one" do
    other = @member.sessions.create!
    sign_in_as(@member)
    body = send_json(:post, web_preview_api_account_password_path, user: @member, current_password: "wrong", password: "NewPassword123", password_confirmation: "NewPassword123")
    assert_response :unprocessable_entity
    assert_equal({ "current_password" => [ "is incorrect" ] }, body.fetch("errors"))
    send_json(:post, web_preview_api_account_password_path, user: @member, current_password: PASSWORD, password: "NewPassword123", password_confirmation: "NewPassword123")
    assert_response :success
    assert @member.reload.authenticate("NewPassword123")
    assert_not Session.exists?(other.id)
    assert_equal 1, @member.sessions.count
  end

  test "two-factor sign-in is set up with a code, its backup codes are shown once, and turning it off needs the password" do
    sign_in_as(@member)
    setup = send_json(:post, web_preview_api_account_two_factor_setup_path, user: @member).fetch("setup")
    assert_equal @member.reload.otp_secret, setup.fetch("secret")
    assert_match %r{\Aotpauth://totp/}, setup.fetch("uri")
    assert_match(/\A<\?xml/, setup.fetch("qr_svg"))
    assert_equal "invalid_code", send_json(:post, web_preview_api_account_two_factor_enable_path, user: @member, otp_code: "000000").fetch("error")
    codes = send_json(:post, web_preview_api_account_two_factor_enable_path, user: @member, otp_code: ROTP::TOTP.new(@member.otp_secret).now).fetch("backup_codes")
    assert_equal User::BACKUP_CODE_COUNT, codes.size
    assert @member.reload.otp_enabled?
    send_json(:post, web_preview_api_account_two_factor_setup_path, user: @member)
    assert_response :conflict
    send_json(:post, web_preview_api_account_backup_codes_path, user: @member, password: "wrong")
    assert_response :unprocessable_entity
    assert_not_equal codes, send_json(:post, web_preview_api_account_backup_codes_path, user: @member, password: PASSWORD).fetch("backup_codes")
    send_json(:post, web_preview_api_account_two_factor_disable_path, user: @member, password: "wrong")
    assert_response :unprocessable_entity
    assert @member.reload.otp_enabled?
    assert_equal({ "enabled" => false }, send_json(:post, web_preview_api_account_two_factor_disable_path, user: @member, password: PASSWORD).dig("profile", "settings", "two_factor"))
  end

  test "a member creates a token with self-service scopes only, sees its secret once, and revokes only their own tokens" do
    sign_in_as(@member)
    send_json(:post, web_preview_api_account_api_tokens_path, user: @member, name: "Bot", scopes: %w[requests:admin])
    assert_response :unprocessable_entity
    send_json(:post, web_preview_api_account_api_tokens_path, user: @member, name: "Bot", scopes: [])
    assert_response :unprocessable_entity
    send_json(:post, web_preview_api_account_api_tokens_path, user: @member, name: "Bot", scopes: { "a" => "search:read" })
    assert_response :unprocessable_entity
    assert_equal %w[search:read], send_json(:post, web_preview_api_account_api_tokens_path, user: @member, name: "One", scopes: "search:read").dig("token", "scopes")
    body = send_json(:post, web_preview_api_account_api_tokens_path, user: @member, name: "Bot", scopes: %w[search:read])
    assert_response :created
    assert APIToken.authenticate(body.fetch("secret"))
    assert_equal [ "Bot", %w[search:read], "active" ], body.fetch("token").values_at("name", "scopes", "state")
    preview_get web_preview_api_account_path, user: @member
    assert_not_includes response.body, body.fetch("secret")
    foreign, = APIToken.issue!(name: "Admin's", user: @admin, scopes: %w[library:read])
    send_json(:post, web_preview_api_account_api_token_revoke_path(foreign), user: @member)
    assert_response :not_found
    assert_not foreign.reload.revoked?
    revoked = send_json(:post, web_preview_api_account_api_token_revoke_path(body.dig("token", "id")), user: @member)
    assert_equal "revoked", revoked.dig("profile", "settings", "api_tokens").find { |token| token.fetch("id") == body.dig("token", "id") }.fetch("state")
  end

  test "an administrator may grant privileged scopes and gets the server settings link" do
    sign_in_as(@admin)
    assert_equal "/admin", account(@admin).dig("profile", "settings", "links", "admin")
    send_json(:post, web_preview_api_account_api_tokens_path, user: @admin, name: "Ops", scopes: %w[requests:admin])
    assert_response :created
  end

  test "every token stays listed and revocable however many were made after it" do
    phone, = APIToken.issue!(name: "Phone", user: @member, scopes: %w[library:read])
    105.times { |index| APIToken.issue!(name: "Script #{index}", user: @member, scopes: %w[search:read]).first.revoke! }
    sign_in_as(@member)
    assert_includes account(@member).dig("profile", "settings", "api_tokens").map { |token| token.fetch("id") }, phone.id.to_s
  end

  test "an OIDC link is removed only with the current password" do
    SettingsService.stub(:oidc_configured?, true) do
      @member.update!(oidc_provider: "oidc", oidc_uid: "abc")
      sign_in_as(@member)
      assert account(@member).dig("profile", "settings", "oidc", "linked")
      assert_nil account(@member).dig("profile", "settings", "oidc", "link_page")
      send_json(:post, web_preview_api_account_oidc_unlink_path, user: @member, current_password: "wrong")
      assert_response :unprocessable_entity
      assert @member.reload.oidc_user?
      send_json(:post, web_preview_api_account_oidc_unlink_path, user: @member, current_password: PASSWORD)
      assert_response :success
      assert_not @member.reload.oidc_user?
    end
  end

  test "account writes need the page's CSRF token and the account header" do
    sign_in_as(@member)
    put web_preview_api_account_profile_path, params: { name: "X" }, headers: { "Accept" => "application/json" }, as: :json
    assert_response :unauthorized
    with_forgery_protection do
      send_json(:post, web_preview_api_account_two_factor_setup_path, user: @member)
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
    assert_nil @member.reload.otp_secret
  end
end
