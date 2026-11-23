# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::HardcoverConnectionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WebPreviewTestHelper

  TOKEN_URL = "https://api.hardcover.app/oauth2/token"
  DEVICE_URL = "https://api.hardcover.app/oauth2/device"
  REVOKE_URL = "https://api.hardcover.app/oauth2/revoke"
  CALLBACK = "https://shelf.example/hardcover/connection/callback"
  ISSUER = "https://api.hardcover.app"
  WARM_PAGE = "/preview/account/connections#hardcover"

  setup do
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = users(:one)
    @admin = users(:two)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    SettingsService.set(:hardcover_oauth_client_secret, "")
    SettingsService.set(:hardcover_oauth_redirect_uri, CALLBACK)
    SettingsService.set(:hardcover_oauth_device_flow_enabled, true)
    SettingsService.set(:hardcover_allow_personal_access, true)
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 404)
    sign_in_as(@member)
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def send_json(path, user: @member, **body)
    post path, params: body, headers: account_headers(user), as: :json
    response.parsed_body
  end

  def hardcover(user: @member)
    preview_get web_preview_api_hardcover_connection_path, user: user
    assert_response :success
    response.parsed_body.fetch("hardcover")
  end

  def start_oauth(user: @member, version: nil)
    body = send_json(web_preview_api_hardcover_authorize_path, user: user, version: version)
    assert_response :success
    URI.parse(body.fetch("authorization_url"))
  end

  def state_of(url)
    Rack::Utils.parse_query(url.query).fetch("state")
  end

  def stub_token(access: "hc_at_warm", refresh: "hc_rt_warm")
    stub_request(:post, TOKEN_URL).to_return(status: 200, body: { access_token: access, refresh_token: refresh, expires_in: 604_800, scope: "read:library" }.to_json)
  end

  def stub_me(id: 4242, username: "reader")
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => id, "username" => username } ] })
  end

  def stub_device(interval: 5, expires_in: 900)
    stub_request(:post, DEVICE_URL).to_return(status: 200, body: { device_code: "synthetic-device-code", user_code: "ABCD-1234", verification_uri: "https://hardcover.app/link",
      verification_uri_complete: "https://hardcover.app/link?code=ABCD-1234", expires_in: expires_in, interval: interval }.to_json)
  end

  def assert_private_answer
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  def assert_returned_to_warm_page(tone, message, user: @member)
    assert_redirected_to "http://www.example.com#{WARM_PAGE}"
    assert_response :see_other
    assert_private_answer
    assert_nil flash[:alert]
    assert_nil flash[:notice]
    assert_equal({ "tone" => tone, "message" => message }, hardcover(user: user).fetch("outcome"))
    assert_nil hardcover(user: user).fetch("outcome"), "an outcome is shown once"
  end

  test "the state names which ways of connecting this server allows and hides the connection while Hardcover is off" do
    body = hardcover
    assert_private_answer
    assert_equal({ "enabled" => true, "methods" => { "sign_in" => true, "code" => true, "api_key" => true }, "connection" => nil, "device" => nil, "outcome" => nil,
      "links" => { "following" => "/hardcover/subscriptions", "api_key_page" => HardcoverIntegration.personal_token_url } }, body)

    SettingsService.set(:hardcover_allow_personal_access, false)
    SettingsService.set(:hardcover_oauth_device_flow_enabled, false)
    assert_equal({ "sign_in" => true, "code" => false, "api_key" => false }, hardcover.fetch("methods"))
    assert_equal({ "following" => "/hardcover/subscriptions" }, hardcover.fetch("links"))

    create_hardcover_connection(@member)
    SettingsService.set(:hardcover_enabled, false)
    body = hardcover
    assert_equal [ false, { "sign_in" => false, "code" => false, "api_key" => false }, nil ], body.values_at("enabled", "methods", "connection")
  end

  test "every change is refused while Hardcover or the chosen way of connecting is turned off, and nothing reaches Hardcover" do
    connection = create_hardcover_connection(@member)
    version = connection.version
    SettingsService.set(:hardcover_enabled, false)
    [ [ web_preview_api_hardcover_api_key_path, { api_key: "hc_pat_value", version: version } ], [ web_preview_api_hardcover_authorize_path, { version: version } ],
      [ web_preview_api_hardcover_device_path, { version: version } ], [ web_preview_api_hardcover_device_poll_path, {} ],
      [ web_preview_api_hardcover_device_cancel_path, {} ], [ web_preview_api_hardcover_disconnect_path, { version: version } ] ].each do |path, body|
      answer = send_json(path, **body)
      assert_response :conflict
      assert_equal [ "hardcover_unavailable", "Hardcover is disabled on this Shelfarr instance." ], answer.values_at("error", "message"), path
      assert_equal false, answer.dig("hardcover", "enabled")
    end
    assert_equal connection.reload.access_token, "hc_at_test_#{@member.id}"
    assert_nil session[:hardcover_oauth]

    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_allow_personal_access, false)
    SettingsService.set(:hardcover_oauth_client_id, "")
    { web_preview_api_hardcover_api_key_path => "Personal API keys are not enabled on this Shelfarr instance.",
      web_preview_api_hardcover_authorize_path => "Hardcover sign-in is not configured. An administrator can add a Hardcover OAuth client in Settings.",
      web_preview_api_hardcover_device_path => "Sign-in with a code is not enabled on this Shelfarr instance." }.each do |path, message|
      answer = send_json(path, api_key: "hc_pat_value", version: version)
      assert_response :conflict
      assert_equal [ "hardcover_unavailable", message ], answer.values_at("error", "message")
    end
    assert_not_requested :post, HardcoverClient::BASE_URL
    assert_not_requested :post, DEVICE_URL
    assert_nil session[:hardcover_oauth]
  end

  test "a personal API key is verified, stored encrypted and never shown or logged" do
    stub_me(id: 77, username: "pat_user")
    output = StringIO.new
    original = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(output)

    answer = send_json(web_preview_api_hardcover_api_key_path, api_key: "Bearer hc_pat_synthetic_value", version: nil)

    assert_response :success
    assert_private_answer
    assert_equal "Connected Hardcover account @pat_user.", answer.fetch("notice")
    connection = @member.reload.hardcover_connection
    assert_equal [ "personal_token", "hc_pat_synthetic_value", 77 ], [ connection.auth_method, connection.access_token, connection.hardcover_user_id ]
    assert_equal "Bearer hc_pat_synthetic_value", hardcover_requests.sole[:authorization]
    assert_equal({ "version" => connection.version, "username" => "pat_user", "profile_url" => "https://hardcover.app/@pat_user", "method" => "api_key", "state" => "active", "problem" => nil },
      answer.dig("hardcover", "connection"))
    raw = HardcoverConnection.connection.select_one("SELECT access_token FROM hardcover_connections WHERE id = #{connection.id}")
    assert_not_includes raw["access_token"], "hc_pat_synthetic_value"
    assert_not_includes response.body, "hc_pat_synthetic_value"
    assert_not_includes output.string, "hc_pat_synthetic_value"
    assert_not_includes hardcover.to_json, "hc_pat_synthetic_value"
  ensure
    ActionController::Base.logger = original
  end

  test "a key Hardcover refuses, a blank key or a malformed request stores nothing" do
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 401, body: "{}")

    answer = send_json(web_preview_api_hardcover_api_key_path, api_key: "wrong", version: nil)
    assert_response :unprocessable_entity
    assert_equal [ "hardcover_refused", "Hardcover rejected that key. Check that it is current and has not been revoked." ], answer.values_at("error", "message")
    assert_nil answer.dig("hardcover", "connection")

    answer = send_json(web_preview_api_hardcover_api_key_path, api_key: "   ", version: nil)
    assert_response :unprocessable_entity
    assert_equal "invalid_api_key", answer.fetch("error")
    send_json(web_preview_api_hardcover_api_key_path, api_key: "x" * 2_001, version: nil)
    assert_response :unprocessable_entity
    send_json(web_preview_api_hardcover_api_key_path, api_key: [ "hc" ], version: nil)
    assert_response :bad_request
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_value")
    assert_response :bad_request
    assert_requested :post, HardcoverClient::BASE_URL, times: 1
    assert_nil @member.reload.hardcover_connection
  end

  test "a page that showed no connection, or another one, cannot replace the one now stored" do
    connection = create_hardcover_connection(@member)
    stub_me(id: 77)
    device = stub_device

    [ web_preview_api_hardcover_api_key_path, web_preview_api_hardcover_authorize_path, web_preview_api_hardcover_device_path ].each do |path|
      [ nil, "stale", connection.version.reverse ].each do |stale|
        answer = send_json(path, api_key: "hc_pat_value", version: stale)
        assert_response :conflict
        assert_equal [ "hardcover_changed", "Your Hardcover connection changed after this page was shown. Review it and try again." ], answer.values_at("error", "message")
        assert_equal connection.version, answer.dig("hardcover", "connection", "version")
      end
    end
    assert_not_requested :post, HardcoverClient::BASE_URL
    assert_not_requested device
    assert_nil session[:hardcover_oauth]
    assert_equal [ 4242, "hc_at_test_#{@member.id}" ], connection.reload.then { |stored| [ stored.hardcover_user_id, stored.access_token ] }
  end

  test "reconnecting with a second Hardcover account replaces the first, revokes its sign-in and restarts Want to Read" do
    first = create_hardcover_connection(@member, refresh_token: "hc_rt_first")
    first.mark_reauthorization_required!("Hardcover rejected the refresh token")
    want_to_read = create_hardcover_subscription(@member, kind: "want_to_read", status: "paused")
    own_list = create_hardcover_subscription(@member, kind: "list", target_id: 99, account_id: 4242, personal: true)
    revoke = stub_request(:post, REVOKE_URL).with(body: hash_including("token" => "hc_rt_first")).to_return(status: 200, body: "{}")
    stub_me(id: 77, username: "second_reader")
    assert_equal({ "version" => first.reload.version, "username" => "reader#{@member.id}", "profile_url" => "https://hardcover.app/@reader#{@member.id}", "method" => "sign_in",
      "state" => "needs_reconnecting", "problem" => "Hardcover rejected the refresh token" }, hardcover.fetch("connection"))

    assert_enqueued_with(job: HardcoverSubscriptionSyncJob, args: [ want_to_read.id, { mode: "snapshot" } ]) do
      send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_second", version: first.version)
    end

    assert_response :success
    assert_requested revoke
    stored = @member.reload.hardcover_connection
    assert_equal [ first.id, 77, "second_reader", "personal_token", "active", nil ], [ stored.id, stored.hardcover_user_id, stored.hardcover_username, stored.auth_method, stored.status, stored.refresh_token ]
    assert_equal 77, want_to_read.reload.hardcover_account_id
    assert own_list.reload.paused?
    assert_equal HardcoverSubscription::PAUSE_OTHER_ACCOUNT, own_list.pause_reason
  end

  test "Hardcover sign-in started here returns to Account ▸ Connections with the account connected" do
    url = start_oauth
    assert_private_answer
    assert_equal [ "https", "hardcover.app", "/oauth2/authorize" ], [ url.scheme, url.host, url.path ]
    query = Rack::Utils.parse_query(url.query)
    assert_equal [ "S256", CALLBACK, "client-123" ], query.values_at("code_challenge_method", "redirect_uri", "client_id")
    assert_match(/\Apreview-[A-Za-z0-9_-]{43}\z/, query.fetch("state"))
    token = stub_token
    stub_me

    get callback_hardcover_connection_path, params: { code: "synthetic-code", state: query.fetch("state"), iss: ISSUER }

    assert_requested token, times: 1
    assert_returned_to_warm_page("success", "Connected Hardcover account @reader.")
    connection = @member.reload.hardcover_connection
    assert_equal [ "oauth", "hc_at_warm", "hc_rt_warm", 4242 ], [ connection.auth_method, connection.access_token, connection.refresh_token, connection.hardcover_user_id ]
    assert_not_includes hardcover.to_json, "hc_at_warm"
  end

  test "a forged, replayed, expired, cancelled or foreign sign-in returns to the warm page without connecting" do
    token = stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    start_oauth
    get callback_hardcover_connection_path, params: { code: "c", state: "preview-forged", iss: ISSUER }
    assert_returned_to_warm_page("error", "That Hardcover sign-in expired or was started elsewhere. Please try again.")

    state = state_of(start_oauth)
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
    assert_returned_to_warm_page("error", "Hardcover did not accept the sign-in (invalid_grant). Check the client ID, secret, and registered redirect URI.")
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
    assert_returned_to_warm_page("error", "That Hardcover sign-in expired or was started elsewhere. Please try again.")
    assert_requested token, times: 1

    state = state_of(start_oauth)
    travel Hardcover::Oauth::PENDING_TTL + 1.second do
      get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
      assert_returned_to_warm_page("error", "That Hardcover sign-in expired or was started elsewhere. Please try again.")
    end

    state = state_of(start_oauth)
    get callback_hardcover_connection_path, params: { error: "access_denied", state: state, iss: ISSUER }
    assert_returned_to_warm_page("error", "Hardcover sign-in was cancelled.")

    state = state_of(start_oauth)
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: "https://evil.example" }
    assert_returned_to_warm_page("error", "Hardcover sign-in failed: the response did not come from Hardcover.")

    assert_requested token, times: 1
    assert_nil @member.reload.hardcover_connection
  end

  test "a sign-in, a code and an outcome belong to the Shelfarr account that started them" do
    stub_device
    send_json(web_preview_api_hardcover_device_path, version: nil)
    assert_equal "ABCD-1234", hardcover.dig("device", "user_code")
    state = state_of(start_oauth)
    token = stub_token
    stub_me

    sign_in_as(@admin)
    assert_nil hardcover(user: @admin).fetch("device")
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
    assert_returned_to_warm_page("error", "That Hardcover sign-in expired or was started elsewhere. Please try again.", user: @admin)
    answer = send_json(web_preview_api_hardcover_device_poll_path, user: @admin)
    assert_equal [ "failed", "Hardcover sign-in expired. Start again." ], answer.values_at("status", "message")
    assert_not_requested token
    assert_nil @admin.reload.hardcover_connection
    assert_nil @member.reload.hardcover_connection

    sign_in_as(@member)
    state = state_of(start_oauth)
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
    sign_in_as(@admin)
    assert_nil hardcover(user: @admin).fetch("outcome")
    preview_get web_preview_api_hardcover_connection_path, user: @member
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    assert_equal 4242, @member.reload.hardcover_connection.hardcover_user_id
    assert_nil @admin.reload.hardcover_connection
  end

  test "sign-in started on the classic page, or by someone outside the preview, keeps its classic answers" do
    post authorize_hardcover_connection_path
    classic_state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
    assert_not classic_state.start_with?("preview-")
    get callback_hardcover_connection_path, params: { code: "c", state: "forged", iss: ISSUER }
    assert_redirected_to profile_path
    assert_match(/expired or was started elsewhere/, flash[:alert])

    state = state_of(start_oauth)
    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    stub_token
    stub_me
    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }
    assert_redirected_to hardcover_subscriptions_path
    assert_equal "Connected Hardcover account @reader.", flash[:notice]

    ENV.delete(WebPreview::Access::VARIABLE)
    get callback_hardcover_connection_path, params: { code: "c", state: "preview-forged", iss: ISSUER }
    assert_redirected_to profile_path
    assert_match(/expired or was started elsewhere/, flash[:alert])
  end

  test "a code started on the classic page keeps its classic page for someone in the preview" do
    stub_device
    post device_hardcover_connection_path
    assert_redirected_to device_hardcover_connection_path
    get device_hardcover_connection_path
    assert_response :success
    assert_select "p", text: "ABCD-1234"
    assert_equal "ABCD-1234", hardcover.dig("device", "user_code")
  end

  test "a sign-in that finishes after another connection was made keeps the newer one and revokes its own grant" do
    stub_me(id: 77, username: "second")
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_other_tab", version: nil)
    newer = @member.reload.hardcover_connection
    revoke = stub_request(:post, REVOKE_URL).with(body: hash_including("token" => "hc_rt_late")).to_return(status: 200, body: "{}")
    stub_token(access: "hc_at_late", refresh: "hc_rt_late")
    stub_me(id: 4242, username: "first")
    newer.destroy!
    state = state_of(start_oauth(version: nil))
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_other_tab", version: nil)
    newer = @member.reload.hardcover_connection

    get callback_hardcover_connection_path, params: { code: "c", state: state, iss: ISSUER }

    assert_returned_to_warm_page("error", "Your Hardcover connection changed after this page was shown. Review it and try again.")
    assert_requested revoke
    assert_equal [ newer.id, newer.version, "hc_pat_other_tab" ], @member.reload.hardcover_connection.then { |stored| [ stored.id, stored.version, stored.access_token ] }

    newer.destroy!
    stub_device
    send_json(web_preview_api_hardcover_device_path, version: nil)
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_other_tab", version: nil)
    newer = @member.reload.hardcover_connection
    stub_token(access: "hc_at_late", refresh: "hc_rt_late")
    travel 6.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "failed", "Your Hardcover connection changed after this page was shown. Review it and try again." ], answer.values_at("status", "message")
    end
    assert_requested revoke, times: 2
    assert_equal newer.version, @member.reload.hardcover_connection.version
  end

  test "disconnecting ends sign-ins started earlier, so an older approval cannot connect afterwards" do
    stub_request(:post, REVOKE_URL).to_return(status: 200, body: "{}")
    stub_device
    stub_token(access: "hc_at_old_approval", refresh: "hc_rt_old_approval")
    send_json(web_preview_api_hardcover_device_path, version: nil)
    oauth_state = state_of(start_oauth(version: nil))
    stub_me(id: 77, username: "key_account")
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_between", version: nil)
    between = @member.reload.hardcover_connection

    answer = send_json(web_preview_api_hardcover_disconnect_path, version: between.version)
    assert_response :success
    assert_nil answer.dig("hardcover", "device")
    stub_me(id: 4242, username: "old_approval")

    travel 6.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "failed", "Hardcover sign-in expired. Start again." ], answer.values_at("status", "message")
    end
    get callback_hardcover_connection_path, params: { code: "c", state: oauth_state, iss: ISSUER }
    assert_returned_to_warm_page("error", "That Hardcover sign-in expired or was started elsewhere. Please try again.")
    assert_not_requested :post, TOKEN_URL
    assert_nil @member.reload.hardcover_connection
  end

  test "a disconnect or cancel that completes while an older sign-in is still finishing wins" do
    stub_request(:post, REVOKE_URL).to_return(status: 200, body: "{}")
    connect_and_disconnect_elsewhere = lambda do
      between = create_hardcover_connection(@member, hardcover_user_id: 77, username: "between")
      assert Hardcover::ConnectionManager.disconnect!(between, expected_version: between.version)
    end
    oauth_state = state_of(start_oauth(version: nil))
    stub_device
    send_json(web_preview_api_hardcover_device_path, version: nil)
    stub_request(:post, TOKEN_URL).to_return do
      connect_and_disconnect_elsewhere.call
      { status: 200, body: { access_token: "hc_at_late", refresh_token: "hc_rt_late", expires_in: 604_800 }.to_json }
    end
    stub_me(id: 4242, username: "late_approval")

    get callback_hardcover_connection_path, params: { code: "c", state: oauth_state, iss: ISSUER }
    assert_returned_to_warm_page("error", "Your Hardcover connection changed after this page was shown. Review it and try again.")
    travel 6.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "failed", "Your Hardcover connection changed after this page was shown. Review it and try again." ], answer.values_at("status", "message")
    end
    assert_nil @member.reload.hardcover_connection
    assert_requested :post, REVOKE_URL, body: hash_including("token" => "hc_rt_late"), times: 2

    stub_hardcover_graphql("ShelfarrMe" => lambda { |_|
      connect_and_disconnect_elsewhere.call
      { "me" => [ { "id" => 5150, "username" => "slow_key" } ] }
    })
    answer = send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_slow", version: nil)
    assert_response :conflict
    assert_equal "hardcover_changed", answer.fetch("error")
    assert_nil @member.reload.hardcover_connection

    stub_request(:post, DEVICE_URL).to_return do
      connect_and_disconnect_elsewhere.call
      { status: 200, body: { device_code: "slow-start", user_code: "SLOW-0001", verification_uri: "https://hardcover.app/link", expires_in: 900, interval: 5 }.to_json }
    end
    stub_token(access: "hc_at_slow_start", refresh: "hc_rt_slow_start")
    stub_me(id: 4242, username: "slow_start")
    send_json(web_preview_api_hardcover_device_path, version: nil)
    travel 6.seconds do
      assert_equal "failed", send_json(web_preview_api_hardcover_device_poll_path).fetch("status")
    end
    assert_nil @member.reload.hardcover_connection

    stub_device
    send_json(web_preview_api_hardcover_device_path, version: nil)
    cancelled_elsewhere = { status: 200, body: { access_token: "hc_at_cancelled", refresh_token: "hc_rt_cancelled", expires_in: 604_800 }.to_json }
    stub_request(:post, TOKEN_URL).to_return do
      Hardcover::ConnectionManager.end_sign_ins!(@member)
      cancelled_elsewhere
    end
    travel 6.seconds do
      assert_equal "failed", send_json(web_preview_api_hardcover_device_poll_path).fetch("status")
    end
    assert_nil @member.reload.hardcover_connection
    assert_requested :post, REVOKE_URL, body: hash_including("token" => "hc_rt_cancelled")
  end

  test "cancelling a code ends sign-ins still waiting in other tabs" do
    stub_device
    send_json(web_preview_api_hardcover_device_path, version: nil)
    generation = @member.reload.hardcover_sign_in_generation
    send_json(web_preview_api_hardcover_device_cancel_path)
    assert_equal generation + 1, @member.reload.hardcover_sign_in_generation
  end

  test "an API key checked while another connection is made does not replace it" do
    stub_hardcover_graphql("ShelfarrMe" => lambda { |_|
      unless @member.hardcover_connection
        create_hardcover_connection(@member, hardcover_user_id: 4242, username: "made_meanwhile")
        Hardcover::ConnectionManager.end_sign_ins!(@member)
      end
      { "me" => [ { "id" => 77, "username" => "slow_key" } ] }
    })

    answer = send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_slow", version: nil)

    assert_response :conflict
    assert_equal "hardcover_changed", answer.fetch("error")
    assert_equal "made_meanwhile", answer.dig("hardcover", "connection", "username")
    assert_equal [ 4242, "hc_at_test_#{@member.id}" ], @member.reload.hardcover_connection.then { |stored| [ stored.hardcover_user_id, stored.access_token ] }
  end

  test "a slow-down answer lengthens the interval the card is told to wait" do
    stub_device
    token = stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "slow_down" }.to_json)
    send_json(web_preview_api_hardcover_device_path, version: nil)
    travel 6.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "pending", 10 ], [ answer.fetch("status"), answer.dig("hardcover", "device", "interval") ]
    end
    travel 12.seconds do
      send_json(web_preview_api_hardcover_device_poll_path)
    end
    assert_requested token, times: 1
  end

  test "sign-in with a code shows the code, honours Hardcover's interval, expires and can be cancelled" do
    stub_device
    token = stub_request(:post, TOKEN_URL).to_return(
      { status: 400, body: { error: "authorization_pending" }.to_json },
      { status: 200, body: { access_token: "hc_at_dev", refresh_token: "hc_rt_dev", expires_in: 604_800 }.to_json }
    )
    stub_me

    answer = send_json(web_preview_api_hardcover_device_path, version: nil)
    assert_response :success
    assert_private_answer
    device = answer.dig("hardcover", "device")
    assert_equal({ "user_code" => "ABCD-1234", "verification_uri" => "https://hardcover.app/link", "verification_uri_complete" => "https://hardcover.app/link?code=ABCD-1234", "interval" => 5 },
      device.except("expires_at"))
    assert_in_delta 15.minutes.from_now, Time.zone.parse(device.fetch("expires_at")), 2.seconds
    assert_not_includes response.body, "synthetic-device-code"

    answer = send_json(web_preview_api_hardcover_device_poll_path)
    assert_equal "pending", answer.fetch("status")
    assert_not_requested token
    travel 6.seconds do
      assert_equal "pending", send_json(web_preview_api_hardcover_device_poll_path).fetch("status")
      assert_requested token, times: 1
    end
    travel 9.seconds do
      assert_equal "pending", send_json(web_preview_api_hardcover_device_poll_path).fetch("status")
      assert_requested token, times: 1
    end
    travel 12.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
    end
    assert_equal [ "approved", "Connected Hardcover account @reader." ], answer.values_at("status", "message")
    assert_nil answer.dig("hardcover", "device")
    assert_equal [ "oauth", "hc_at_dev", 4242 ], @member.reload.hardcover_connection.then { |stored| [ stored.auth_method, stored.access_token, stored.hardcover_user_id ] }
    assert_not_includes response.body, "hc_at_dev"

    @member.hardcover_connection.destroy!
    stub_device(expires_in: 60)
    send_json(web_preview_api_hardcover_device_path, version: nil)
    travel 61.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "failed", "Hardcover sign-in expired. Start again." ], answer.values_at("status", "message")
      assert_nil answer.dig("hardcover", "device")
    end

    send_json(web_preview_api_hardcover_device_path, version: nil)
    answer = send_json(web_preview_api_hardcover_device_cancel_path)
    assert_nil answer.dig("hardcover", "device")
    assert_equal "failed", send_json(web_preview_api_hardcover_device_poll_path).fetch("status")
    assert_requested token, times: 2
    assert_nil @member.reload.hardcover_connection
  end

  test "a declined code ends the sign-in" do
    stub_device
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "access_denied" }.to_json)
    send_json(web_preview_api_hardcover_device_path, version: nil)
    travel 6.seconds do
      answer = send_json(web_preview_api_hardcover_device_poll_path)
      assert_equal [ "failed", "Hardcover sign-in was declined." ], answer.values_at("status", "message")
    end
    assert_nil hardcover.fetch("device")
  end

  test "disconnecting removes only the connection the page showed and pauses what needs it" do
    connection = create_hardcover_connection(@member, refresh_token: "hc_rt_revoke_me")
    want_to_read = create_hardcover_subscription(@member, kind: "want_to_read")
    revoke = stub_request(:post, REVOKE_URL).with(body: hash_including("token" => "hc_rt_revoke_me")).to_return(status: 200, body: "{}")

    shown = connection.version
    connection.update!(access_token: "hc_at_newer_grant", refresh_token: "hc_rt_newer_grant", last_verified_at: 1.minute.from_now)
    answer = send_json(web_preview_api_hardcover_disconnect_path, version: shown)
    assert_response :conflict
    assert_equal "hardcover_changed", answer.fetch("error")
    assert_equal "hc_at_newer_grant", connection.reload.access_token, "a newer grant for the same Hardcover account is kept"
    connection.update!(refresh_token: "hc_rt_revoke_me")
    send_json(web_preview_api_hardcover_disconnect_path)
    assert_response :bad_request

    assert_no_difference -> { Request.count } do
      answer = send_json(web_preview_api_hardcover_disconnect_path, version: connection.version)
    end
    assert_response :success
    assert_equal "Hardcover account disconnected. Requests already created were kept.", answer.fetch("notice")
    assert_nil answer.dig("hardcover", "connection")
    assert_requested revoke
    assert_not HardcoverConnection.exists?(connection.id)
    assert want_to_read.reload.paused?

    answer = send_json(web_preview_api_hardcover_disconnect_path, version: shown)
    assert_response :success
    assert_equal "No Hardcover account is connected.", answer.fetch("notice")
  end

  test "a disconnect that loses the race to a reconnection keeps the new account" do
    connection = create_hardcover_connection(@member)
    stub_request(:post, REVOKE_URL).to_return(status: 200, body: "{}")
    shown = HardcoverConnection.find(connection.id)
    connection.update!(hardcover_user_id: 77, hardcover_username: "second")

    assert_not Hardcover::ConnectionManager.disconnect!(shown, expected_version: shown.version)
    assert_equal 77, connection.reload.hardcover_user_id
    assert Hardcover::ConnectionManager.disconnect!(shown)
    assert_not HardcoverConnection.exists?(connection.id)
  end

  test "only people in the preview reach the connection, for their own account and with a CSRF token" do
    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    preview_get web_preview_api_hardcover_connection_path
    assert_response :not_found
    send_json(web_preview_api_hardcover_api_key_path, api_key: "hc_pat_value", version: nil)
    assert_response :not_found

    ENV[WebPreview::Access::VARIABLE] = @member.id.to_s
    preview_get web_preview_api_hardcover_connection_path, user: @admin
    assert_response :unauthorized
    with_forgery_protection do
      post web_preview_api_hardcover_api_key_path, params: { api_key: "hc_pat_value", version: nil }, headers: account_headers(@member), as: :json
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
    assert_not_requested :post, HardcoverClient::BASE_URL
    assert_nil @member.reload.hardcover_connection
  end
end

class WebPreview::HardcoverConnectionMountTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  BASE = "/shelf"

  setup do
    @previous_root = ActionController::Base.relative_url_root
    ActionController::Base.relative_url_root = BASE
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = users(:one).id.to_s
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    SettingsService.set(:hardcover_oauth_redirect_uri, "")
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 404)
  end

  teardown do
    ActionController::Base.relative_url_root = @previous_root
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def app
    @app ||= Rack::URLMap.new(BASE => Rails.application)
  end

  test "under a deployment path the advertised callback address is unchanged from classic and the sign-in returns to the warm page there" do
    sign_in_as(users(:one))
    post "#{BASE}/preview/api/v1/account/hardcover/authorize", params: { version: nil }, headers: account_headers(users(:one)).merge("HOST" => "localhost"), as: :json
    assert_response :success
    query = Rack::Utils.parse_query(URI.parse(response.parsed_body.fetch("authorization_url")).query)
    assert_equal "http://localhost/hardcover/connection/callback", query.fetch("redirect_uri")

    get "#{BASE}/hardcover/connection/callback", params: { error: "access_denied", state: query.fetch("state"), iss: "https://api.hardcover.app" }, headers: { "HOST" => "localhost" }
    assert_redirected_to "http://localhost#{BASE}/preview/account/connections#hardcover"
    get "#{BASE}/preview/api/v1/account/hardcover", headers: account_headers(users(:one)).merge("HOST" => "localhost")
    assert_equal({ "tone" => "error", "message" => "Hardcover sign-in was cancelled." }, response.parsed_body.dig("hardcover", "outcome"))
    assert_equal "#{BASE}/hardcover/subscriptions", response.parsed_body.dig("hardcover", "links", "following")
  end
end
