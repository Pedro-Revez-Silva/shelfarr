# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminAudibleBackupTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  TOKEN = "bridge-secret-5531aa"
  COMPANION = "https://libation.test"
  LOGIN = "https://www.amazon.com/ap/signin?openid.return_to=private-callback-3311"
  LANDING = "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=private-code-8842"
  IMMEDIATE_REFRESH = Class.new { def debounce = yield }.new

  def run
    Turbo::StreamsChannel.stub(:refresh_debouncer_for, IMMEDIATE_REFRESH) { super }
  end

  setup do
    @member = users(:one)
    @admin = users(:two)
    @other_admin = User.create!(username: "second_admin", name: "Second Admin", password: "Password123!", role: :admin)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin, @other_admin ].map { |user| user.id.to_s }.join(",")
    @original_audiobook_output_path = SettingsService.get(:audiobook_output_path)
    @audiobook_output_path = Dir.mktmpdir("audible-preview-storage")
    SettingsService.set(:audiobook_output_path, @audiobook_output_path)
    OwnedLibraryConnection.delete_all
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    SettingsService.set(:audiobook_output_path, @original_audiobook_output_path)
    FileUtils.rm_rf(@audiobook_output_path)
  end

  def create_connection(**attributes)
    OwnedLibraryConnection.create!(url: COMPANION, allow_private_network: false, bridge_token: TOKEN, enabled: true, **attributes)
  end

  def stub_accounts(authenticated: true)
    stub_request(:get, "#{COMPANION}/v1/accounts")
      .to_return(status: 200, body: { accounts: [ { account: "reader@example.com", locale: "us", authenticated: authenticated } ] }.to_json)
  end

  def state(user: @admin)
    sign_in_as(user)
    preview_get web_preview_api_admin_audible_path, user: user
    response.parsed_body
  end

  def write(verb, path, body = {}, user: @admin)
    public_send(verb, path, params: body.to_json, headers: account_headers(user).merge("Content-Type" => "application/json"))
    response.parsed_body
  end

  def write_paths(connection)
    item = connection.owned_library_items.create!(external_id: "B0WRITE001", title: "Write Path", ownership_type: "purchased")
    [
      [ :put, web_preview_api_admin_audible_companion_path, { companion: { url: COMPANION, enabled: true } } ],
      [ :post, web_preview_api_admin_audible_test_path, {} ],
      [ :post, web_preview_api_admin_audible_sign_in_path, { account: "reader@example.com", locale: "us" } ],
      [ :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: "0" * 64, response_url: LANDING } ],
      [ :post, web_preview_api_admin_audible_sync_path, {} ],
      [ :post, web_preview_api_admin_audible_existing_backup_path, { confirm: true } ],
      [ :post, web_preview_api_admin_audible_existing_backup_dismiss_path, {} ],
      [ :put, web_preview_api_admin_audible_automation_path, { automation: { scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 60, automatic_backup_enabled: false } } ],
      [ :post, web_preview_api_admin_audible_item_backup_path(item_id: item.id), {} ]
    ]
  end

  def snapshot
    OwnedLibraryConnection.order(:id).map { |connection| connection.attributes.merge("bridge_token" => connection.bridge_token) } +
      OwnedMediaImport.order(:id).map(&:attributes)
  end

  def with_log
    log = StringIO.new
    previous = Rails.logger
    previous_record_logger = ActiveRecord::Base.logger
    Rails.logger = ActiveSupport::Logger.new(log).tap { |logger| logger.level = :debug }
    ActionController::Base.logger = Rails.logger
    ActiveRecord::Base.logger = Rails.logger
    yield
    log.string
  ensure
    Rails.logger = previous
    ActionController::Base.logger = previous
    ActiveRecord::Base.logger = previous_record_logger
  end

  test "with the preview off, for a member, another account or signed out, nothing is read, written or contacted" do
    connection = create_connection
    paths = write_paths(connection)
    before = snapshot

    with_env(WebPreview::Access::VARIABLE => "") do
      sign_in_as(@admin)
      preview_get web_preview_api_admin_audible_path, user: @admin
      assert_response :not_found
      paths.each do |verb, path, body|
        write(verb, path, body)
        assert_response :not_found, path
      end
    end

    sign_in_as(@member)
    preview_get web_preview_api_admin_audible_path, user: @member
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
    preview_get web_preview_api_admin_audible_catalogue_path, user: @member
    assert_response :not_found
    paths.each do |verb, path, body|
      write(verb, path, body, user: @member)
      assert_response :not_found, path
    end

    sign_in_as(@admin)
    paths.each do |verb, path, body|
      write(verb, path, body, user: @member)
      assert_response :unauthorized, path
      assert_equal "account_changed", response.parsed_body.fetch("error")
    end

    delete session_path
    preview_get web_preview_api_admin_audible_path, user: @admin
    assert_response :unauthorized
    paths.each do |verb, path, body|
      write(verb, path, body)
      assert_response :unauthorized, path
    end
    assert_equal before, snapshot
    assert_not_requested :any, /libation\.test/
  end

  test "every Audible write needs the page's CSRF token" do
    connection = create_connection
    paths = write_paths(connection)
    before = snapshot
    sign_in_as(@admin)
    with_forgery_protection do
      paths.each do |verb, path, body|
        write(verb, path, body)
        assert_response :unprocessable_entity, path
        assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      end
      assert_equal before, snapshot

      token = csrf_token
      VCR.turned_off do
        stub_accounts
        post web_preview_api_admin_audible_existing_backup_dismiss_path, params: {}.to_json,
          headers: account_headers(@admin).merge("X-CSRF-Token" => token, "Content-Type" => "application/json")
      end
      assert_response :success
    end
    assert connection.reload.backlog_backup_decided?
  end

  test "an administrator demoted or removed after loading the page cannot change the connection" do
    connection = create_connection
    sign_in_as(@admin)
    @admin.update!(role: :user)
    write :post, web_preview_api_admin_audible_existing_backup_dismiss_path
    assert_response :not_found
    assert_not connection.reload.backlog_backup_decided?

    @admin.update_columns(role: User.roles[:admin])
    sign_in_as(@admin)
    @admin.soft_delete!
    write :post, web_preview_api_admin_audible_existing_backup_dismiss_path
    assert_includes [ 401, 404 ], response.status
    assert_not connection.reload.backlog_backup_decided?
  end

  test "an unsaved connection shows the classic defaults without saving anything, and the token is never sent back" do
    body = state
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal 0, OwnedLibraryConnection.count
    assert_equal({
      "saved" => false, "url" => OwnedLibraryConnection.default_libation_url, "default_url" => OwnedLibraryConnection.default_libation_url,
      "bridge_token_saved" => false, "token_file_managed" => false, "enabled" => false, "allow_private_network" => true, "timeout_seconds" => 30,
      "companion_version" => nil, "provider_version" => nil, "status" => "needs_setup", "problem" => nil, "locked" => false
    }, body.fetch("connection"))
    assert_equal "not_ready", body.dig("sign_in", "state")
    assert_equal "never_synced", body.dig("sync", "state")
    assert_equal false, body.dig("sync", "available")
    assert_equal %w[us uk australia canada france germany india italy japan spain], body.fetch("marketplaces").map { |entry| entry.fetch("value") }
    assert_equal [ 60, 360, 720, 1_440, 4_320, 10_080 ], body.dig("automation", "intervals").map { |entry| entry.fetch("minutes") }

    preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
    assert_equal({ "account" => @admin.id.to_s, "query" => "", "page" => 1, "pages" => 1, "total" => 0, "synced" => false, "items" => [] }, response.parsed_body)

    write :post, web_preview_api_admin_audible_sync_path
    assert_response :not_found
  end

  test "saving creates the connection, a blank token keeps the stored one, and the token never appears in answers or logs" do
    sign_in_as(@admin)
    log = with_log do
      VCR.turned_off do
        stub_accounts
        write :put, web_preview_api_admin_audible_companion_path, { companion: { url: "#{COMPANION}/", bridge_token: TOKEN, enabled: true, allow_private_network: false, timeout_seconds: 45 } }
      end
    end
    assert_response :success
    assert_equal "Audible backup connection saved.", response.parsed_body.dig("outcome", "message")
    connection = OwnedLibraryConnection.sole
    assert_equal [ COMPANION, TOKEN, true, 45, "libation", "Audible Backup" ], [ connection.url, connection.bridge_token, connection.enabled?, connection.timeout_seconds, connection.provider, connection.name ]
    assert_not_includes response.body, TOKEN
    assert_not_includes log, TOKEN
    assert_equal true, response.parsed_body.dig("connection", "bridge_token_saved")

    VCR.turned_off do
      stub_accounts
      write :put, web_preview_api_admin_audible_companion_path, { companion: { url: COMPANION, bridge_token: "", enabled: true, allow_private_network: false, timeout_seconds: 50 } }
    end
    assert_response :success
    assert_equal [ TOKEN, 50 ], [ connection.reload.bridge_token, connection.timeout_seconds ]
    assert_equal "connected", response.parsed_body.dig("sign_in", "state")
  end

  test "a rejected connection answers with field errors and changes nothing" do
    connection = create_connection(enabled: false)
    before = snapshot
    sign_in_as(@admin)
    log = with_log do
      write :put, web_preview_api_admin_audible_companion_path, { companion: { url: "https://user:pa55word@libation.example/?k=1", enabled: false, allow_private_network: false, timeout_seconds: 500 } }
    end
    assert_response :unprocessable_entity
    errors = response.parsed_body.fetch("errors")
    assert_equal %w[timeout_seconds url], errors.map { |error| error.fetch("field") }.uniq.sort
    assert errors.all? { |error| error.fetch("message").start_with?("Request timeout", "Companion address") }
    assert_not_includes log, "pa55word"
    assert_equal before, snapshot

    write :put, web_preview_api_admin_audible_companion_path, { companion: { url: 5, enabled: "yes" } }
    assert_response :bad_request
    assert_equal "invalid_request", response.parsed_body.fetch("error")
    write :put, web_preview_api_admin_audible_companion_path, { companion: "url" }
    assert_response :bad_request
    assert_equal before, snapshot
    assert connection.reload
  end

  test "turning the connection on refuses when audiobook storage is not ready" do
    connection = create_connection(enabled: false)
    SettingsService.set(:audiobook_output_path, File.join(@audiobook_output_path, "missing", "nested"))
    FileUtils.chmod(0o500, @audiobook_output_path)
    sign_in_as(@admin)
    write :put, web_preview_api_admin_audible_companion_path, { companion: { url: COMPANION, enabled: true } }
    assert_response :unprocessable_entity
    assert_equal [ "base" ], response.parsed_body.fetch("errors").map { |error| error.fetch("field") }
    assert_match(/\AAudiobook storage is not ready/, response.parsed_body.dig("errors", 0, "message"))
    assert_not connection.reload.enabled?
  ensure
    FileUtils.chmod(0o700, @audiobook_output_path)
  end

  test "changing the companion while Libation works, or its address while backups wait, is refused" do
    connection = create_connection(sync_status: "queued")
    sign_in_as(@admin)
    body = write :put, web_preview_api_admin_audible_companion_path, { companion: { url: "https://other-libation.test", enabled: true, bridge_token: "replacement-token" } }
    assert_response :success
    assert_equal({ "tone" => "error", "message" => "Wait for the current Libation operation or Audible sign-in to finish before changing the connection." }, body.fetch("outcome"))
    assert_equal true, body.dig("connection", "locked")
    assert_equal [ COMPANION, TOKEN ], [ connection.reload.url, connection.bridge_token ]

    connection.update!(sync_status: "idle")
    item = connection.owned_library_items.create!(external_id: "B0PENDING1", title: "Waiting", ownership_type: "purchased")
    item.owned_media_imports.create!(status: "pending", requested_by: @admin)
    VCR.turned_off do
      stub_accounts
      body = write :put, web_preview_api_admin_audible_companion_path, { companion: { url: "https://other-libation.test", enabled: true, bridge_token: "replacement-token" } }
    end
    assert_equal "Finish queued Audible backups and resolve recoverable ones before changing the companion address or token.", body.dig("outcome", "message")
    assert_equal COMPANION, connection.reload.url
  end

  test "Test keeps only version numbers and known health words, so no token rotated during it can be shown" do
    file = File.join(@audiobook_output_path, "bridge.token")
    File.write(file, "first-token-4411aa\n")
    with_env("SHELFARR_LIBATION_TOKEN_FILE" => file, "SHELFARR_LIBATION_URL" => "http://127.0.0.1:3999") do
      connection = OwnedLibraryConnection.create!(url: OwnedLibraryConnection.default_libation_url, allow_private_network: true, enabled: true)
      sign_in_as(@admin)
      VCR.turned_off do
        stub_request(:get, "#{connection.url}/health").to_return do
          File.write(file, "second-token-5522bb\n")
          { status: 200, body: { status: "first-token-4411aa" }.to_json }
        end
        stub_request(:get, "#{connection.url}/version").to_return do
          File.write(file, "third-token-6633cc\n")
          { status: 200, body: { companionVersion: "v1.4.0-beta.2", libationVersion: "14.2.0-second-token-5522bb" }.to_json }
        end
        stub_request(:get, "#{connection.url}/v1/accounts").to_return(status: 200, body: { accounts: [] }.to_json)
        write :post, web_preview_api_admin_audible_test_path
        assert_equal "Connected to the Libation companion (v1.4.0-beta.2).", response.parsed_body.dig("outcome", "message")
        assert_equal [ "v1.4.0-beta.2", nil ], [ connection.reload.companion_version, connection.provider_version ]
        state
      end
      %w[first-token-4411aa second-token-5522bb third-token-6633cc].each { |secret| assert_not_includes response.body, secret }
    end
  end

  test "Test and the state never show a stored token or anything as long as a companion bearer, even when the companion returns it" do
    connection = create_connection(bridge_token: "9.8.7")
    sign_in_as(@admin)
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/health").to_return(status: 200, body: { status: "ok" }.to_json)
      stub_request(:get, "#{COMPANION}/version").to_return(status: 200, body: { companionVersion: "9.8.7", libationVersion: "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16" }.to_json)
      stub_accounts
      write :post, web_preview_api_admin_audible_test_path
      assert_equal "Connected to the Libation companion; status: ok.", response.parsed_body.dig("outcome", "message")
      assert_equal [ nil, nil ], [ connection.reload.companion_version, connection.provider_version ]

      connection.update_columns(companion_version: "123456.123456.123456.123456-beta.123456", provider_version: "14.2.0")
      body = state
      assert_equal [ nil, "14.2.0" ], body.fetch("connection").values_at("companion_version", "provider_version")
    end
  end

  test "Test reports versions and health, records them, and keeps the token out of a failure" do
    connection = create_connection
    sign_in_as(@admin)
    body = nil
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/health").to_return(status: 200, body: { status: "ok" }.to_json)
      stub_request(:get, "#{COMPANION}/version").to_return(status: 200, body: { companionVersion: "1.4.0", libationVersion: "14.2.1" }.to_json)
      stub_accounts
      body = write :post, web_preview_api_admin_audible_test_path
    end
    assert_equal({ "tone" => "success", "message" => "Connected to the Libation companion (1.4.0 / Libation 14.2.1); status: ok." }, body.fetch("outcome"))
    assert_equal [ "1.4.0", "14.2.1" ], [ connection.reload.companion_version, connection.provider_version ]
    assert_equal [ "1.4.0", "14.2.1" ], body.fetch("connection").values_at("companion_version", "provider_version")

    client = Object.new
    client.define_singleton_method(:token_file_managed?) { false }
    client.define_singleton_method(:secret_values) { [ TOKEN ] }
    client.define_singleton_method(:health) { raise LibationCompanionClient::ConnectionError, "refused with #{TOKEN}" }
    client.define_singleton_method(:accounts) { raise LibationCompanionClient::ConnectionError, "down #{TOKEN}" }
    LibationCompanionClient.stub(:new, client) do
      body = write :post, web_preview_api_admin_audible_test_path
    end
    assert_equal({ "tone" => "error", "message" => "Could not connect to the Libation companion: refused with [hidden]" }, body.fetch("outcome"))
    assert_equal [ "unavailable", "down [hidden]" ], body.fetch("connection").values_at("status", "problem")
    assert_not_includes response.body, TOKEN
  end

  test "sign-in hands over only a checked Amazon link and a token bound to this pending sign-in, this account and one use" do
    connection = create_connection
    sign_in_as(@admin)
    log = with_log do
      VCR.turned_off do
        stub_request(:post, "#{COMPANION}/v1/auth/start")
          .with { |request| JSON.parse(request.body) == { "account" => "reader@example.com", "locale" => "uk", "reregister" => true } }
          .to_return(status: 200, body: { sessionId: "companion-session-7", loginUrl: LOGIN, expiresAt: 10.minutes.from_now.iso8601 }.to_json)
        write :post, web_preview_api_admin_audible_sign_in_path, { account: "reader@example.com", locale: "uk", reregister: true }
      end
    end
    assert_response :success
    sign_in = response.parsed_body.fetch("sign_in")
    assert_equal [ "pending", LOGIN ], sign_in.values_at("state", "login_url")
    token = sign_in.fetch("sign_in_token")
    assert_match(/\A\h{64}\z/, token)
    assert_not_includes response.body, "companion-session-7"
    [ "companion-session-7", "private-callback-3311", "reader@example.com" ].each { |secret| assert_not_includes log, secret }
    assert_not_requested :get, "#{COMPANION}/v1/accounts"

    assert_equal token, state.dig("sign_in", "sign_in_token")
    other = state(user: @other_admin).fetch("sign_in")
    assert_equal LOGIN, other.fetch("login_url")
    assert_not_equal token, other.fetch("sign_in_token")

    sign_in_as(@other_admin)
    write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: token, response_url: LANDING }, user: @other_admin
    assert_equal "This Audible sign-in has expired or was already used. Start again.", response.parsed_body.dig("outcome", "message")
    assert connection.reload.auth_pending?

    sign_in_as(@admin)
    log = with_log do
      VCR.turned_off do
        stub_request(:post, "#{COMPANION}/v1/auth/complete")
          .with { |request| JSON.parse(request.body) == { "sessionId" => "companion-session-7", "responseUrl" => LANDING } }
          .to_return(status: 204)
        stub_accounts
        write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: token, response_url: LANDING }
      end
    end
    assert_equal({ "tone" => "success", "message" => "Audible account connected through Libation." }, response.parsed_body.fetch("outcome"))
    assert_equal "connected", response.parsed_body.dig("sign_in", "state")
    assert_nil connection.reload.auth_session_id
    assert_not_includes log, "private-code-8842"

    write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: token, response_url: LANDING }
    assert_equal "This Audible sign-in has expired or was already used. Start again.", response.parsed_body.dig("outcome", "message")
    assert_requested :post, "#{COMPANION}/v1/auth/complete", times: 1
  end

  test "a stored sign-in link that is not Amazon or Audible is never handed to the page" do
    create_connection(auth_session_id: "session-x", auth_login_url: "https://phish.example/ap/signin", auth_expires_at: 5.minutes.from_now)
    body = state
    assert_equal "pending", body.dig("sign_in", "state")
    assert_nil body.dig("sign_in", "login_url")
    assert_not_includes response.body, "phish.example"
  end

  test "sign-in is refused while Libation works and malformed sign-in input is rejected before the companion is contacted" do
    create_connection(sync_status: "syncing")
    sign_in_as(@admin)
    body = write :post, web_preview_api_admin_audible_sign_in_path, { account: "reader@example.com", locale: "us" }
    assert_equal "error", body.dig("outcome", "tone")
    assert_match(/before changing accounts/, body.dig("outcome", "message"))
    write :post, web_preview_api_admin_audible_sign_in_path, { account: [ "x" ], locale: "us" }
    assert_response :bad_request
    write :post, web_preview_api_admin_audible_sign_in_path, { account: "reader@example.com", locale: "us", reregister: "1" }
    assert_response :bad_request
    write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: 1, response_url: LANDING }
    assert_response :bad_request
    assert_not_requested :any, /libation\.test/
  end

  test "sync queues one job, a second press says it is already running, and polling while it runs never asks the companion" do
    connection = create_connection
    sign_in_as(@admin)
    VCR.turned_off do
      stub_accounts
      assert_enqueued_jobs 1, only: OwnedLibrarySyncJob do
        write :post, web_preview_api_admin_audible_sync_path
      end
      assert_equal({ "tone" => "success", "message" => "Audible library sync queued." }, response.parsed_body.fetch("outcome"))
      assert_equal [ "queued", "Sync queued…", false ], response.parsed_body.fetch("sync").values_at("state", "action", "available")
      assert_equal true, response.parsed_body.fetch("working")

      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        write :post, web_preview_api_admin_audible_sync_path
      end
      assert_equal "An Audible library sync is already queued or running.", response.parsed_body.dig("outcome", "message")
      3.times { state }
    end
    assert connection.reload.queued?
    assert_not_requested :get, "#{COMPANION}/v1/accounts"
  end

  test "the catalogue filters and pages like classic and offers the same per-title backup actions" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    52.times { |index| connection.owned_library_items.create!(external_id: format("B0FILL%04d", index), title: format("Filler %02d", index), authors: [ "Common Author" ], ownership_type: "purchased") }
    plain = connection.owned_library_items.create!(external_id: "B0PLAIN001", title: "Dune", authors: [ "Frank Herbert" ], ownership_type: "purchased")
    connection.owned_library_items.create!(external_id: "B0SUBS0001", title: "Dune Messiah", authors: [ "Frank Herbert" ], ownership_type: "subscription")
    failed = connection.owned_library_items.create!(external_id: "B0FAIL0001", title: "Dune Failed", authors: [ "Frank Herbert" ], ownership_type: "purchased")
    failed.owned_media_imports.create!(status: "failed", requested_by: @admin, error_message: "Libation said #{TOKEN} was wrong")
    local = Book.create!(title: "Dune Local", author: "Frank Herbert", book_type: :audiobook, file_path: "/audiobooks/dune-local")
    conflict = connection.owned_library_items.create!(external_id: "B0CONF0001", title: "Dune Local", authors: [ "Frank Herbert" ], ownership_type: "purchased")
    shelved = connection.owned_library_items.create!(external_id: "B0SHELF001", title: "Dune Shelved", authors: [ "Frank Herbert" ], ownership_type: "purchased", book: local)

    sign_in_as(@admin)
    preview_get web_preview_api_admin_audible_catalogue_path(q: " DUNE "), user: @admin
    body = response.parsed_body
    assert_equal [ "DUNE", 1, 1, 5 ], body.values_at("query", "page", "pages", "total")
    rows = body.fetch("items").index_by { |item| item.fetch("title") }
    assert_equal [ "Dune", "Dune Failed", "Dune Local", "Dune Messiah", "Dune Shelved" ], body.fetch("items").map { |item| item.fetch("title") }
    assert_equal({ "id" => plain.id.to_s, "title" => "Dune", "author" => "Frank Herbert", "ownership" => "purchased", "book_id" => nil, "origin" => nil,
      "detail" => nil, "state" => "not_backed_up", "action" => { "label" => "Back up", "separate_edition" => false, "available" => true } }, rows.fetch("Dune"))
    assert_equal [ "not_eligible", nil ], rows.fetch("Dune Messiah").values_at("state", "action")
    assert_equal [ "failed", "Libation said [hidden] was wrong", "Retry backup", "manual" ], [ *rows.fetch("Dune Failed").values_at("state", "detail"), rows.dig("Dune Failed", "action", "label"), rows.dig("Dune Failed", "origin") ]
    assert_equal [ "possible_match", { "label" => "Back up separately", "separate_edition" => true, "available" => true } ], rows.fetch("Dune Local").values_at("state", "action")
    assert_equal [ "in_shelfarr", local.id.to_s, nil ], rows.fetch("Dune Shelved").values_at("state", "book_id", "action")
    assert_not_includes response.body, TOKEN
    assert shelved

    preview_get web_preview_api_admin_audible_catalogue_path(page: "99"), user: @admin
    assert_equal [ 2, 2, 57 ], response.parsed_body.values_at("page", "pages", "total")
    assert_equal 7, response.parsed_body.fetch("items").size
    preview_get web_preview_api_admin_audible_catalogue_path(page: "abc"), user: @admin
    assert_response :bad_request
    assert conflict
  end

  test "backing up a title queues one job, refuses a possible match until chosen separately, and reports subscriptions" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    plain = connection.owned_library_items.create!(external_id: "B0PLAIN001", title: "Dune", ownership_type: "purchased")
    subscription = connection.owned_library_items.create!(external_id: "B0SUBS0001", title: "Dune Messiah", ownership_type: "subscription")
    Book.create!(title: "Dune Local", author: "Frank Herbert", book_type: :audiobook, file_path: "/audiobooks/dune-local")
    conflict = connection.owned_library_items.create!(external_id: "B0CONF0001", title: "Dune Local", authors: [ "Frank Herbert" ], ownership_type: "purchased")
    sign_in_as(@admin)

    VCR.turned_off do
      stub_accounts
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        write :post, web_preview_api_admin_audible_item_backup_path(item_id: plain.id)
      end
      assert_equal({ "tone" => "success", "message" => "Backup of “Dune” queued through Libation." }, response.parsed_body.fetch("outcome"))
      assert_equal plain.id.to_s, response.parsed_body.fetch("item")
      assert_equal @admin, plain.owned_media_imports.sole.requested_by

      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        write :post, web_preview_api_admin_audible_item_backup_path(item_id: plain.id)
      end
      assert_equal "This Audible backup is already queued or running.", response.parsed_body.dig("outcome", "message")

      write :post, web_preview_api_admin_audible_item_backup_path(item_id: subscription.id)
      assert_equal "Only titles confirmed as purchased can be backed up.", response.parsed_body.dig("outcome", "message")

      write :post, web_preview_api_admin_audible_item_backup_path(item_id: conflict.id)
      assert_equal "error", response.parsed_body.dig("outcome", "tone")
      assert_empty conflict.owned_media_imports

      write :post, web_preview_api_admin_audible_item_backup_path(item_id: conflict.id), { separate_edition: "1" }
      assert_response :bad_request
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        write :post, web_preview_api_admin_audible_item_backup_path(item_id: conflict.id), { separate_edition: true }
      end
      assert conflict.owned_media_imports.sole.separate_edition?
    end

    write :post, web_preview_api_admin_audible_item_backup_path(item_id: 999_999)
    assert_response :not_found
  end

  test "a failed enqueue marks the backup failed instead of leaving it queued" do
    connection = create_connection
    item = connection.owned_library_items.create!(external_id: "B0PLAIN001", title: "Dune", ownership_type: "purchased")
    sign_in_as(@admin)
    VCR.turned_off do
      stub_accounts
      OwnedMediaBackupJob.stub(:perform_later, ->(*) { raise "queue offline" }) do
        write :post, web_preview_api_admin_audible_item_backup_path(item_id: item.id)
      end
    end
    assert_equal({ "tone" => "error", "message" => "Shelfarr could not queue the Libation backup. Try again." }, response.parsed_body.fetch("outcome"))
    assert_equal [ "failed", "Shelfarr could not queue the Libation backup" ], item.owned_media_imports.sole.slice(:status, :error_message).values
  end

  test "the existing-library backup needs an explicit confirmation, queues eligible purchases and can be put off" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    connection.owned_library_items.create!(external_id: "B0OLD00001", title: "Old Purchase", ownership_type: "purchased")
    sign_in_as(@admin)
    VCR.turned_off do
      stub_accounts
      body = state
      assert_equal({ "available" => true, "prompt" => true, "total" => 0, "remaining" => 0, "processed" => 0, "counts" => [] }, body.fetch("existing_backup"))

      write :post, web_preview_api_admin_audible_existing_backup_path, { confirm: "1" }
      assert_response :bad_request
      assert_equal 0, OwnedMediaImport.count

      write :post, web_preview_api_admin_audible_existing_backup_path, { confirm: true }
      assert_equal "1 existing Audible purchase added to the background backup queue. Libation processes one title at a time.", response.parsed_body.dig("outcome", "message")
      assert_equal 1, response.parsed_body.dig("existing_backup", "total")
      assert_equal true, response.parsed_body.fetch("working")

      write :post, web_preview_api_admin_audible_existing_backup_dismiss_path
      assert_equal false, response.parsed_body.dig("existing_backup", "prompt")
    end
    assert connection.reload.backlog_backup_decided?
  end

  test "automation keeps classic order of checks and assigns new-purchase backups to the administrator who saves them" do
    connection = create_connection
    sign_in_as(@admin)
    path = web_preview_api_admin_audible_automation_path
    VCR.turned_off do
      stub_accounts
      write :put, path, { automation: { scheduled_sync_enabled: false, scheduled_sync_interval_minutes: 60, automatic_backup_enabled: true } }
      assert_equal "Automatic backups need scheduled library sync. Turn both on and save again.", response.parsed_body.dig("outcome", "message")
      write :put, path, { automation: { scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 60, automatic_backup_enabled: true } }
      assert_equal "Run a first library sync before turning on automatic backups. It sets the existing-library baseline.", response.parsed_body.dig("outcome", "message")
      assert_not connection.reload.scheduled_sync_enabled?

      connection.update!(last_synced_at: 1.hour.ago)
      write :put, path, { automation: { scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 360, automatic_backup_enabled: true } }
      assert_equal "success", response.parsed_body.dig("outcome", "tone")
      automation = response.parsed_body.fetch("automation")
      assert_equal [ true, 360, true, @admin.name, true, false ], automation.values_at("scheduled_sync_enabled", "interval_minutes", "automatic_backup_enabled", "owner", "owner_ready", "baseline_ready")
      assert_equal @admin, connection.reload.automatic_backup_user

      write :put, path, { automation: { scheduled_sync_enabled: "true", scheduled_sync_interval_minutes: 60, automatic_backup_enabled: false } }
      assert_response :bad_request
      write :put, path, { automation: { scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 61, automatic_backup_enabled: false } }
      assert_response :unprocessable_entity
      assert_equal 360, connection.reload.scheduled_sync_interval_minutes

      write :put, path, { automation: { scheduled_sync_enabled: false, scheduled_sync_interval_minutes: 360, automatic_backup_enabled: true } }
      assert_equal "Audible automation turned off. Manual sync and backup stay available.", response.parsed_body.dig("outcome", "message")
      assert_equal [ false, false, nil ], [ connection.reload.scheduled_sync_enabled?, connection.automatic_backup_enabled?, connection.automatic_backup_user ]
    end
  end

  test "the classic page sends listed administrators to the matching warm card and stays classic otherwise" do
    create_connection
    sign_in_as(@admin)
    library = web_preview_server_category_path(category: "library")
    {
      {} => "#{library}#audible",
      { tab: "overview" } => "#{library}#audible",
      { tab: "connection" } => "#{library}#audible-connection",
      { tab: "automation" } => "#{library}#audible-automation",
      { tab: "catalog" } => "#{library}#audible-catalogue",
      { tab: "catalog", q: "  Dune ", page: "3" } => "#{library}?audible_page=3&audible_q=Dune#audible-catalogue",
      { q: "Dune", page: "1" } => "#{library}?audible_q=Dune#audible-catalogue",
      { tab: "unknown", page: "abc" } => "#{library}#audible"
    }.each do |query, target|
      get admin_owned_library_connections_path(query)
      assert_redirected_to target, query.inspect
    end

    VCR.turned_off do
      stub_accounts
      get admin_owned_library_connections_path(q: [ "x" ])
    end
    assert_response :success

    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      VCR.turned_off do
        stub_accounts
        get admin_owned_library_connections_path
      end
      assert_response :success
    end

    VCR.turned_off do
      stub_accounts
      post dismiss_existing_backup_admin_owned_library_connection_path(OwnedLibraryConnection.sole)
      follow_redirect!
    end
    assert_response :success
    assert_select "h1", "Audible Backup"

    sign_in_as(@member)
    get admin_owned_library_connections_path
    assert_redirected_to root_path
  end

  test "the overview no longer lists anything as missing from the preview" do
    sign_in_as(@admin)
    preview_get web_preview_api_admin_overview_path, user: @admin
    assert_equal [], response.parsed_body.fetch("pending")
  end

  test "companion text never carries the bridge token or a sign-in callback's query into an answer" do
    connection = create_connection(last_synced_at: 1.hour.ago, sync_status: "failed", last_sync_error: "Libation rejected #{LANDING}")
    item = connection.owned_library_items.create!(external_id: "B0FAIL0001", title: "Dune", ownership_type: "purchased")
    item.owned_media_imports.create!(status: "failed", requested_by: @admin, error_message: "Callback #{LANDING} with #{TOKEN}")
    sign_in_as(@admin)
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/health").to_return(status: 200, body: { status: "ok #{TOKEN}" }.to_json)
      stub_request(:get, "#{COMPANION}/version").to_return(status: 200, body: { companionVersion: "1.4 #{TOKEN}", libationVersion: "14.2" }.to_json)
      stub_accounts
      write :post, web_preview_api_admin_audible_test_path
      assert_equal "Connected to the Libation companion (14.2).", response.parsed_body.dig("outcome", "message")
      assert_nil response.parsed_body.dig("connection", "companion_version")
      assert_equal [ nil, "14.2" ], [ connection.reload.companion_version, connection.provider_version ]
      assert_equal "Libation rejected https://www.amazon.com/[hidden]", response.parsed_body.dig("sync", "error")
      state
      preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
      assert_equal "Callback https://www.amazon.com/[hidden] with [hidden]", response.parsed_body.dig("items", 0, "detail")
    end
    [ TOKEN, "private-code-8842" ].each { |secret| assert_not_includes response.body, secret }
  end

  test "an address from another marketplace than the pending sign-in is refused before anything is claimed or sent" do
    connection = create_connection
    connection.update!(auth_session_id: "companion-session-7", auth_login_url: "https://www.amazon.co.uk/ap/signin?x=1", auth_expires_at: 10.minutes.from_now)
    token = WebPreview::AudibleBackupJson.sign_in_token(connection, @admin, "companion-session-7")
    sign_in_as(@admin)
    body = write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: token, response_url: "https://www.amazon.com/ap/maplanding?code=1" }
    assert_equal "That address is from a different Audible marketplace than this sign-in. Paste the address from the tab this sign-in opened. Nothing was sent to Libation.", body.dig("outcome", "message")
    assert connection.reload.auth_pending?
    assert_not_requested :any, /libation\.test/
    assert OwnedLibraryConnectionWorkflow.same_marketplace?("https://www.amazon.co.uk/ap/signin", "https://www.audible.co.uk/x")
    assert OwnedLibraryConnectionWorkflow.same_marketplace?("https://www.amazon.com.au/ap/signin", "https://www.amazon.com.au/x")
    assert_not OwnedLibraryConnectionWorkflow.same_marketplace?("https://www.amazon.com/ap/signin", "https://www.amazon.com.au/x")
  end

  test "an address that is not an https Amazon or Audible page is refused before anything is claimed or sent" do
    connection = create_connection(auth_session_id: "companion-session-7", auth_login_url: LOGIN, auth_expires_at: 10.minutes.from_now)
    sign_in_as(@admin)
    token = WebPreview::AudibleBackupJson.sign_in_token(connection, @admin, "companion-session-7")
    [ "http://www.amazon.com/ap/maplanding?code=1", "https://evil.example/ap/maplanding", "https://user:pw@www.amazon.com/x", "not a url", "https://www.amazon.com/#{'a' * 17.kilobytes}" ].each do |address|
      body = write :post, web_preview_api_admin_audible_sign_in_complete_path, { sign_in_token: token, response_url: address }
      assert_equal "Paste the full https address the Amazon or Audible tab ends on. Nothing was sent to Libation.", body.dig("outcome", "message"), address.first(40)
      assert_equal "pending", body.dig("sign_in", "state")
    end
    assert connection.reload.auth_pending?
    assert_not_requested :any, /libation\.test/
  end

  test "a token read from the mounted token file, even one rotated during Test, and addresses in versions are never stored or shown" do
    file = File.join(@audiobook_output_path, "bridge.token")
    File.write(file, "initial-token-1209cc\n")
    with_env("SHELFARR_LIBATION_TOKEN_FILE" => file, "SHELFARR_LIBATION_URL" => "http://127.0.0.1:3999") do
      connection = OwnedLibraryConnection.create!(url: OwnedLibraryConnection.default_libation_url, allow_private_network: true, enabled: true)
      sign_in_as(@admin)
      VCR.turned_off do
        stub_request(:get, "#{connection.url}/health").to_return do
          File.write(file, "file-token-6631aa\n")
          { status: 200, body: { status: "ok" }.to_json }
        end
        stub_request(:get, "#{connection.url}/version").with(headers: { "Authorization" => "Bearer file-token-6631aa" })
          .to_return do
            File.write(file, "rotated-token-7742bb\n")
            { status: 200, body: { companionVersion: "1.4 file-token-6631aa", libationVersion: "14.2 https://www.amazon.com/ap/x?code=1" }.to_json }
          end
        stub_request(:get, "#{connection.url}/v1/accounts").to_return(status: 200, body: { accounts: [] }.to_json)
        write :post, web_preview_api_admin_audible_test_path
        assert_equal "Connected to the Libation companion; status: ok.", response.parsed_body.dig("outcome", "message")
        assert_equal [ nil, nil, true ], response.parsed_body.fetch("connection").values_at("companion_version", "provider_version", "token_file_managed")
        assert_equal [ nil, nil ], [ connection.reload.companion_version, connection.provider_version ]
        state
      end
      [ "initial-token-1209cc", "file-token-6631aa", "rotated-token-7742bb", "code=1" ].each { |secret| assert_not_includes response.body, secret }
    end
  end

  test "polling while an existing-library batch waits between titles never asks the companion, and the card keeps polling" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    item = connection.owned_library_items.create!(external_id: "B0PENDING1", title: "Waiting", ownership_type: "purchased")
    item.owned_media_imports.create!(status: "pending", requested_by: @admin)
    VCR.turned_off do
      3.times do
        body = state
        assert_equal [ true, 1, "busy" ], [ body.fetch("working"), body.dig("existing_backup", "remaining"), body.dig("connection", "status") ]
      end
    end
    assert_not_requested :any, /libation\.test/
  end

  test "a pending sign-in keeps the card polling so an expired one is noticed" do
    connection = create_connection(auth_session_id: "companion-session-7", auth_login_url: LOGIN, auth_expires_at: 10.minutes.from_now)
    assert_equal [ "pending", true ], state.values_at("sign_in", "working").then { |sign_in, working| [ sign_in.fetch("state"), working ] }
    travel 11.minutes do
      VCR.turned_off do
        stub_accounts(authenticated: false)
        body = state
        assert_equal [ "needs_sign_in", false ], [ body.dig("sign_in", "state"), body.fetch("working") ]
      end
    end
    assert_nil connection.reload.auth_session_id
  end

  test "a title backed up separately shows its own progress and failure instead of the possible match" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    Book.create!(title: "Dune Local", author: "Frank Herbert", book_type: :audiobook, file_path: "/audiobooks/dune-local")
    item = connection.owned_library_items.create!(external_id: "B0CONF0001", title: "Dune Local", authors: [ "Frank Herbert" ], ownership_type: "purchased")
    media_import = item.owned_media_imports.create!(status: "queued", requested_by: @admin, separate_edition: true)
    sign_in_as(@admin)
    preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
    row = response.parsed_body.dig("items", 0)
    assert_equal [ "queued", { "label" => "Queued…", "separate_edition" => true, "available" => false } ], row.values_at("state", "action")
    media_import.update_columns(status: "failed", error_message: "Libation could not download it")
    preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
    row = response.parsed_body.dig("items", 0)
    assert_equal [ "failed", "Libation could not download it", { "label" => "Back up separately", "separate_edition" => true, "available" => true } ], row.values_at("state", "detail", "action")
  end

  test "the revision changes when a sync or backup moves, is admin-only and never asks the companion" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    item = connection.owned_library_items.create!(external_id: "B0PLAIN001", title: "Dune", ownership_type: "purchased")
    sign_in_as(@member)
    preview_get web_preview_api_admin_audible_revision_path, user: @member
    assert_response :not_found

    sign_in_as(@admin)
    read = lambda do
      preview_get web_preview_api_admin_audible_revision_path, user: @admin
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      response.parsed_body.fetch("revision")
    end
    idle = read.call
    assert_match(/\A\h{16}\z/, idle)
    assert_equal idle, read.call
    travel 1.second
    connection.update!(sync_status: "syncing", sync_started_at: Time.current)
    syncing = read.call
    assert_not_equal idle, syncing
    travel 1.second
    item.owned_media_imports.create!(status: "queued", requested_by: @admin)
    assert_not_equal syncing, read.call
    assert_not_requested :any, /libation\.test/
  end

  test "a custom bridge token however short is never shown as a version" do
    connection = create_connection(bridge_token: "1.2", last_synced_at: 1.hour.ago)
    connection.update_columns(companion_version: "1.2", provider_version: "14.2.0")
    VCR.turned_off do
      stub_accounts
      body = state
      assert_equal [ nil, "14.2.0" ], body.fetch("connection").values_at("companion_version", "provider_version")
    end
  end

  test "a state read whose counts are overtaken while Libation lists accounts carries a revision the next check sees as old" do
    connection = create_connection(last_synced_at: 1.hour.ago)
    item = connection.owned_library_items.create!(external_id: "B0PLAIN001", title: "Dune", ownership_type: "purchased")
    sign_in_as(@admin)
    body = nil
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/v1/accounts").to_return do
        travel 1.second
        item.owned_media_imports.create!(status: "queued", requested_by: users(:two))
        { status: 200, body: { accounts: [ { account: "reader@example.com", locale: "us", authenticated: true } ] }.to_json }
      end
      body = state
    end
    travel_back
    assert_equal [ false, 0 ], [ body.fetch("working"), body.dig("active_backups", "total") ]
    preview_get web_preview_api_admin_audible_revision_path, user: @admin
    assert_not_equal body.fetch("revision"), response.parsed_body.fetch("revision")
  end

  test "a short custom bridge token is hidden in backup diagnostics too" do
    connection = create_connection(bridge_token: "1.2", last_synced_at: 1.hour.ago)
    item = connection.owned_library_items.create!(external_id: "B0FAIL0001", title: "Dune", ownership_type: "purchased")
    item.owned_media_imports.create!(status: "failed", requested_by: @admin, error_message: "Bridge value 1.2 was rejected")
    sign_in_as(@admin)
    preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
    assert_equal "Bridge value [hidden] was rejected", response.parsed_body.dig("items", 0, "detail")
  end

  test "a mounted token that was rotated away stays hidden in an old diagnostic, and a token in an account label is hidden" do
    file = File.join(@audiobook_output_path, "bridge.token")
    old_token = "old-mounted-token-#{'a' * 24}"
    File.write(file, "#{old_token}\n")
    with_env("SHELFARR_LIBATION_TOKEN_FILE" => file, "SHELFARR_LIBATION_URL" => "http://127.0.0.1:3999") do
      connection = OwnedLibraryConnection.create!(url: OwnedLibraryConnection.default_libation_url, allow_private_network: true, enabled: true, last_synced_at: 1.hour.ago)
      item = connection.owned_library_items.create!(external_id: "B0FAIL0001", title: "Dune", ownership_type: "purchased")
      item.owned_media_imports.create!(status: "failed", requested_by: @admin, error_message: "Bearer #{old_token} was rejected")
      File.write(file, "new-mounted-token-#{'b' * 24}\n")
      sign_in_as(@admin)
      preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
      assert_equal "Bearer [hidden] was rejected", response.parsed_body.dig("items", 0, "detail")
      assert_not_includes response.body, old_token
    end

    custom = OwnedLibraryConnection.sole
    custom.update_columns(url: COMPANION, bridge_token: "custom-label-token", allow_private_network: false)
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/v1/accounts")
        .to_return(status: 200, body: { accounts: [ { account: "reader@example.com", locale: "us", authenticated: true, name: "Reader custom-label-token" } ] }.to_json)
      body = state
      assert_equal "Reader [hidden]", body.dig("sign_in", "accounts", 0, "label")
    end
  end

  test "companion text in every field is sanitised: a bracketed rotated token, a token as a locale, a token in a title" do
    file = File.join(@audiobook_output_path, "bridge.token")
    bracketed = "[old]-mounted-token-#{'c' * 20}"
    File.write(file, "#{bracketed}\n")
    with_env("SHELFARR_LIBATION_TOKEN_FILE" => file, "SHELFARR_LIBATION_URL" => "http://127.0.0.1:3999") do
      connection = OwnedLibraryConnection.create!(url: OwnedLibraryConnection.default_libation_url, allow_private_network: true, enabled: true, last_synced_at: 1.hour.ago)
      item = connection.owned_library_items.create!(external_id: "B0FAIL0001", title: "Dune #{bracketed}", ownership_type: "purchased")
      item.owned_media_imports.create!(status: "failed", requested_by: @admin, error_message: "Bearer #{bracketed} was rejected")
      File.write(file, "new-mounted-token-#{'d' * 24}\n")
      sign_in_as(@admin)
      preview_get web_preview_api_admin_audible_catalogue_path, user: @admin
      assert_equal [ "Dune [hidden]", "Bearer [hidden] was rejected" ], response.parsed_body.fetch("items").first.values_at("title", "detail")
      assert_not_includes response.body, "mounted-token"
    end

    custom = OwnedLibraryConnection.sole
    custom.update_columns(url: COMPANION, bridge_token: "locale-token-1", allow_private_network: false)
    VCR.turned_off do
      stub_request(:get, "#{COMPANION}/v1/accounts")
        .to_return(status: 200, body: { accounts: [ { account: "reader@example.com", locale: "locale-token-1", authenticated: true, name: "Reader" } ] }.to_json)
      body = state
      assert_equal({ "label" => "Reader", "marketplace" => "Unknown marketplace", "authenticated" => true }, body.dig("sign_in", "accounts", 0))
      assert_not_includes response.body, "locale-token-1"
    end
  end
end
