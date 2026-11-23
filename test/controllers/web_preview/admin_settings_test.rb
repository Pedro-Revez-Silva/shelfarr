# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminSettingsTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  SECRETS = {
    prowlarr_api_key: "prowlarr-secret-4821",
    hardcover_api_token: "hardcover-secret-7310",
    telegram_bot_token: "123456:telegram-secret-9921",
    discord_webhook_url: "https://discord.example/api/webhooks/discord-secret-5512",
    oidc_client_secret: "oidc-secret-3318",
    zlibrary_password: "zlibrary-secret-6604"
  }.freeze

  setup do
    clear_settings_env!
    @member = users(:one)
    @admin = users(:two)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    restore_settings_env!
    ProwlarrClient.reset_connection!
    LibraryPlatformClient.reset_connections!
  end

  def admin_get(path)
    sign_in_as(@admin)
    preview_get path, user: @admin
  end

  def save_group(group, values, user: @admin)
    put web_preview_api_admin_settings_group_path(group: group), params: { values: values }, headers: account_headers(user), as: :json
  end

  def probe(name, values = {}, user: @admin)
    post web_preview_api_admin_settings_probe_path(probe: name), params: { values: values }, headers: account_headers(user), as: :json
  end

  def settings_json
    admin_get web_preview_api_admin_settings_path
    assert_response :success
    response.parsed_body
  end

  def fields_of(body)
    body.fetch("categories").flat_map { |category| category.fetch("groups") }.flat_map { |group| group.fetch("fields") + group.fetch("advanced") }
  end

  def field_json(body, key)
    fields_of(body).find { |field| field.fetch("key") == key.to_s }
  end

  def write_paths(id: "1")
    [
      [ :put, web_preview_api_admin_settings_group_path(group: "new_requests"), { values: { queue_batch_size: "7" } } ],
      [ :post, web_preview_api_admin_settings_probe_path(probe: "webhook"), {} ],
      [ :post, web_preview_api_admin_health_check_path, {} ],
      [ :post, web_preview_api_admin_update_check_path, {} ],
      [ :post, web_preview_api_admin_settings_library_sync_path, {} ],
      [ :post, web_preview_api_admin_settings_telegram_chats_path, { code: "123456" } ],
      [ :post, web_preview_api_admin_telegram_chat_pause_path(id: id), {} ],
      [ :post, web_preview_api_admin_telegram_chat_resume_path(id: id), {} ],
      [ :delete, web_preview_api_admin_telegram_chat_path(id: id), {} ]
    ]
  end

  def read_paths
    [ web_preview_api_admin_overview_path, web_preview_api_admin_settings_path, web_preview_api_admin_settings_library_path, web_preview_api_admin_telegram_chats_path ]
  end

  test "with the preview switched off every Server page and API answers not found, even for an administrator" do
    [ nil, "", "nope" ].each do |raw|
      with_env(WebPreview::Access::VARIABLE => raw) do
        sign_in_as(@admin)
        [ web_preview_server_path, web_preview_server_category_path(category: "policy") ].each do |path|
          get path
          assert_response :not_found, path
        end
        read_paths.each do |path|
          preview_get path, user: @admin
          assert_response :not_found, path
          assert_equal({ "error" => "not_found" }, response.parsed_body)
        end
        write_paths.each do |verb, path, params|
          send(verb, path, params: params, headers: account_headers(@admin), as: :json)
          assert_response :not_found, path
        end
        assert_equal 5, SettingsService.get(:queue_batch_size)
      end
    end
  end

  test "an administrator who is not in the preview list is refused like anyone else" do
    with_preview_users(@member) do
      sign_in_as(@admin)
      preview_get web_preview_api_admin_settings_path, user: @admin
      assert_response :not_found
      save_group("new_requests", { queue_batch_size: "7" })
      assert_response :not_found
    end
    assert_equal 5, SettingsService.get(:queue_batch_size)
  end

  test "a member gets not found from every Server read and write and nothing changes" do
    chat = TelegramChatAuthorization.create!(chat_id: "-100777", chat_title: "Readers", approved_at: Time.current)
    sign_in_as(@member)
    read_paths.each do |path|
      preview_get path, user: @member
      assert_response :not_found, path
      assert_equal({ "error" => "not_found" }, response.parsed_body)
    end
    assert_no_enqueued_jobs do
      write_paths(id: chat.id.to_s).each do |verb, path, params|
        send(verb, path, params: params, headers: account_headers(@member), as: :json)
        assert_response :not_found, path
      end
    end
    assert_equal 5, SettingsService.get(:queue_batch_size)
    assert TelegramChatAuthorization.exists?(chat.id)
    assert_not chat.reload.paused?
  end

  test "a signed-out browser is refused every Server read and write" do
    read_paths.each do |path|
      preview_get path, user: @admin
      assert_response :unauthorized, path
      assert_equal({ "error" => "signed_out" }, response.parsed_body)
    end
    save_group("new_requests", { queue_batch_size: "7" })
    assert_response :unauthorized
    assert_equal 5, SettingsService.get(:queue_batch_size)
  end

  test "a request for a different account is refused before it reads or writes" do
    sign_in_as(@admin)
    get web_preview_api_admin_settings_path, headers: account_headers(@member)
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    save_group("new_requests", { queue_batch_size: "7" }, user: @member)
    assert_response :unauthorized
    probe("indexer", { prowlarr_url: "http://prowlarr.test" }, user: @member)
    assert_response :unauthorized
    assert_equal 5, SettingsService.get(:queue_batch_size)
  end

  test "saves and probes need the page's CSRF token" do
    sign_in_as(@admin)
    with_forgery_protection do
      save_group("new_requests", { queue_batch_size: "7" })
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      probe("webhook")
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      assert_equal 5, SettingsService.get(:queue_batch_size)

      token = csrf_token
      put web_preview_api_admin_settings_group_path(group: "new_requests"), params: { values: { queue_batch_size: "7" } }, headers: account_headers(@admin).merge("X-CSRF-Token" => token), as: :json
      assert_response :success
    end
    assert_equal 7, SettingsService.get(:queue_batch_size)
  end

  test "every setting definition is in exactly one card or the internal list" do
    placed = WebPreview::AdminSettingsLayout.groups.flat_map { |group| WebPreview::AdminSettingsLayout.keys_for(group) }
    duplicates = placed.tally.select { |_, count| count > 1 }.keys
    assert_empty duplicates, "Placed in more than one card"
    assert_equal SettingsService::DEFINITIONS.keys.sort, (placed + WebPreview::AdminSettingsLayout::HIDDEN_KEYS).sort
    assert_empty placed & WebPreview::AdminSettingsLayout::HIDDEN_KEYS

    keys = fields_of(settings_json).map { |field| field.fetch("key") }
    assert_equal (SettingsService::DEFINITIONS.keys - WebPreview::AdminSettingsLayout::HIDDEN_KEYS).map(&:to_s).sort, keys.sort
    assert_equal keys.uniq, keys
    ids = WebPreview::AdminSettingsLayout.groups.map { |group| group[:id] }
    assert_equal ids.uniq, ids
  end

  test "every setting the classic page offered as a fixed list of choices is a choice here, with the same values" do
    fields = fields_of(settings_json).index_by { |field| field.fetch("key") }
    {
      "indexer_provider" => %w[none prowlarr jackett newznab],
      "indexer_search_scope" => SettingsService::INDEXER_SEARCH_SCOPES,
      "library_platform" => SettingsService::LIBRARY_PLATFORMS,
      "completed_download_import_mode" => SettingsService::COMPLETED_DOWNLOAD_IMPORT_MODES,
      "default_request_format" => SettingsService::DEFAULT_REQUEST_FORMATS,
      "metadata_source" => %w[auto hardcover google_books openlibrary comic_vine],
      "oidc_default_role" => %w[user admin],
      "telegram_update_mode" => %w[polling webhook]
    }.each do |key, values|
      assert_equal "choice", fields.fetch(key).fetch("input"), key
      assert_equal values, fields.fetch(key).fetch("options").map { |option| option.fetch("value") }, key
    end
    fields.each_value do |field|
      assert_includes %w[choice order events], field.fetch("input"), field.fetch("key") if field.key?("options")
    end
  end

  test "every probe and health service a card names exists" do
    WebPreview::AdminSettingsLayout.groups.each do |group|
      group.fetch(:probes, []).each { |entry| assert_includes ServerSettings::Probe::NAMES, entry[:id], group[:id] }
      assert_includes SystemHealth::SERVICES, group[:health], group[:id] if group[:health]
      assert_includes WebPreview::AdminSettingsLayout.keys_for(group), group[:toggle], group[:id] if group[:toggle]
    end
  end

  test "secrets are never sent, only whether one is saved, and environment-managed values are read-only" do
    SECRETS.each { |key, value| SettingsService.set(key, value) }
    SystemHealth.for_service("indexer").check_failed!(message: "Login with #{SECRETS[:prowlarr_api_key]} failed")
    with_env("SHELFARR_SETTING_OIDC_ISSUER" => "https://login.example", "SHELFARR_SETTING_WEBHOOK_TOKEN" => "env-webhook-secret-2290") do
      body = settings_json
      text = response.body
      SECRETS.each_value { |secret| assert_not_includes text, secret }
      assert_not_includes text, "env-webhook-secret-2290"
      assert_not_includes text, SettingsService.get(:api_token)

      token = field_json(body, :hardcover_api_token)
      assert_equal({ "input" => "secret", "configured" => true, "value" => nil }, token.slice("input", "configured", "value"))
      assert_equal false, field_json(body, :comic_vine_api_key).fetch("configured")
      assert_equal "https://login.example", field_json(body, :oidc_issuer).fetch("value")
      assert_equal "SHELFARR_SETTING_OIDC_ISSUER", field_json(body, :oidc_issuer).fetch("managed_by")
      webhook_token = field_json(body, :webhook_token)
      assert_equal [ "SHELFARR_SETTING_WEBHOOK_TOKEN", true, nil ], webhook_token.values_at("managed_by", "configured", "value")

      indexer = body.fetch("categories").flat_map { |category| category["groups"] }.find { |group| group["id"] == "indexer" }
      assert_equal "Login with [hidden] failed", indexer.dig("health", "message")

      admin_get web_preview_api_admin_overview_path
      SECRETS.each_value { |secret| assert_not_includes response.body, secret }
    end
  end

  test "a card saves only its own settings, together, with the same follow-up work as the classic page" do
    sign_in_as(@admin)
    assert_enqueued_with(job: HealthCheckJob, args: [ { service: "hardcover" } ]) do
      save_group("hardcover", { hardcover_enabled: "true", hardcover_api_token: "new-hardcover-token", hardcover_search_limit: "12" })
    end
    assert_response :success
    assert_equal({ "tone" => "success", "message" => "Settings saved." }, response.parsed_body.fetch("outcome"))
    assert_equal %w[hardcover_api_token hardcover_search_limit].sort, response.parsed_body.fetch("changed").sort
    assert_equal "new-hardcover-token", SettingsService.get(:hardcover_api_token)
    assert_equal 12, SettingsService.get(:hardcover_search_limit)
    assert_not_includes response.body, "new-hardcover-token"

    save_group("hardcover", { queue_batch_size: "9" })
    assert_response :bad_request
    assert_equal "invalid_request", response.parsed_body.fetch("error")
    assert_equal 5, SettingsService.get(:queue_batch_size)

    save_group("nonexistent", { queue_batch_size: "9" })
    assert_response :bad_request
    save_group("hardcover", { hardcover_api_token: { nested: "value" } })
    assert_response :bad_request
  end

  test "a blank or unchanged secret keeps the stored value and a card with no changes writes nothing" do
    SettingsService.set(:prowlarr_api_key, SECRETS[:prowlarr_api_key])
    sign_in_as(@admin)
    assert_no_enqueued_jobs do
      save_group("indexer", { prowlarr_api_key: "" })
      assert_response :success
      assert_equal "There were no changes to save.", response.parsed_body.dig("outcome", "message")
      save_group("indexer", { prowlarr_api_key: SECRETS[:prowlarr_api_key] })
      assert_equal [], response.parsed_body.fetch("changed")
    end
    assert_equal SECRETS[:prowlarr_api_key], SettingsService.get(:prowlarr_api_key)
  end

  test "an environment-managed setting is left alone when a card is saved" do
    with_env("SHELFARR_SETTING_WEBHOOK_URL" => "https://env.example/hook") do
      sign_in_as(@admin)
      save_group("webhook", { webhook_url: "https://other.example/hook", webhook_topic: "books" })
      assert_response :success
      assert_equal [ "webhook_topic" ], response.parsed_body.fetch("changed")
      assert_equal "https://env.example/hook", SettingsService.get(:webhook_url)
      assert_nil Setting.find_by(key: "webhook_url")&.value&.then { |value| value if value.include?("other.example") }
    end
  end

  test "one invalid value saves nothing in its card" do
    sign_in_as(@admin)
    save_group("automatic_selection", { auto_select_enabled: "true", auto_select_confidence_threshold: "150" })
    assert_response :unprocessable_entity
    assert_equal [ { "key" => "auto_select_confidence_threshold", "message" => "Auto-Select Confidence Threshold: must be an integer from 0 to 100" } ], response.parsed_body.fetch("errors")
    assert_equal false, SettingsService.get(:auto_select_enabled)
  end

  VALIDATION_MATRIX = [
    [ "automatic_selection", { auto_select_confidence_threshold: "150" } ],
    [ "automatic_selection", { auto_select_min_seeders: "lots" } ],
    [ "new_requests", { default_request_format: "scroll" } ],
    [ "new_requests", { auto_approve_requests: "maybe" } ],
    [ "importing", { completed_download_import_mode: "teleport" } ],
    [ "importing", { library_import_folder_mode: "0600" } ],
    [ "importing", { library_import_file_mode: "abc" } ],
    [ "naming", { ebook_path_template: "{unknown_variable}" } ],
    [ "naming", { ebook_filename_template: "" } ],
    [ "naming", { audiobook_path_template: "../{title}" } ],
    [ "indexer", { prowlarr_url: "ftp://prowlarr.test" } ],
    [ "ebooks_com", { ebooks_com_enabled: "true" } ],
    [ "ebooks_com", { ebooks_com_enabled: "true", ebooks_com_country_code: "ZZ" } ],
    [ "ebooks_com", { ebooks_com_search_limit: "99" } ],
    [ "formats", { ebook_min_file_size: "huge" } ],
    [ "formats", { ebook_min_file_size: "20 MB", ebook_max_file_size: "5 MB" } ],
    [ "languages", { enabled_languages: { "nested" => "x" } } ],
    [ "health_checks", { health_check_interval: "30" } ]
  ].freeze

  test "every validation rule answers the same in the preview as on the classic page, and saves nothing in either" do
    sign_in_as(@admin)
    VALIDATION_MATRIX.each do |group, values|
      before = Setting.order(:key).pluck(:key, :value)
      save_group(group, values)
      preview_status = response.status
      preview_text = preview_status == 422 ? response.parsed_body.fetch("errors").map { |error| error.fetch("message") }.join(". ") : response.parsed_body["message"]
      assert_equal before, Setting.order(:key).pluck(:key, :value), "preview #{values}"

      patch bulk_update_admin_settings_path, params: { settings: values }
      classic_text = flash[:alert]
      assert_equal before, Setting.order(:key).pluck(:key, :value), "classic #{values}"

      assert_includes [ 422, 400 ], preview_status, values.inspect
      assert_equal classic_text, preview_text, values.inspect if preview_status == 422
    end
  end

  test "a draft probe tests the typed values without changing the saved connection's health" do
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "http://saved-prowlarr.test")
    SettingsService.set(:prowlarr_api_key, SECRETS[:prowlarr_api_key])
    SystemHealth.for_service("indexer").check_succeeded!(message: "Connection successful")
    seen = nil
    sign_in_as(@admin)
    ConnectionProbe.stub(:indexer, ->(**args) { seen = args; RemoteResult::Failed.new(StandardError.new("down")) }) do
      probe("indexer", { indexer_provider: "prowlarr", prowlarr_url: "http://typed-prowlarr.test", prowlarr_api_key: "", queue_batch_size: "1" })
    end
    assert_response :success
    assert_equal({ "tone" => "error", "message" => "Prowlarr connection failed." }, response.parsed_body.fetch("outcome"))
    assert_equal({ provider: "prowlarr", url: "http://typed-prowlarr.test", api_key: SECRETS[:prowlarr_api_key] }, seen)
    assert_equal "healthy", SystemHealth.for_service("indexer").status
    assert_equal 5, SettingsService.get(:queue_batch_size)

    ConnectionProbe.stub(:indexer, ->(**) { RemoteResult::Ok.new(true) }) { probe("indexer") }
    assert_equal "success", response.parsed_body.dig("outcome", "tone")
  end

  test "a probe's message never repeats a stored secret, and unknown probes are refused" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, SECRETS[:telegram_bot_token])
    SettingsService.set(:telegram_webhook_secret, "webhook-secret-for-telegram")
    sign_in_as(@admin)
    failure = Integrations::Telegram::Client::DeliveryError.new("POST https://api.telegram.org/bot#{SECRETS[:telegram_bot_token]}/getMe failed")
    Integrations::Telegram::Client.stub(:get_me, ->(*) { raise failure }) { probe("telegram") }
    assert_response :success
    assert_equal "POST https://api.telegram.org/bot[hidden]/getMe failed", response.parsed_body.dig("outcome", "message")

    probe("unknown_probe")
    assert_response :bad_request
  end

  test "the Telegram webhook action changes delivery and reports it, as the classic button does" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, SECRETS[:telegram_bot_token])
    SettingsService.set(:telegram_webhook_secret, "webhook-secret-for-telegram")
    registered = nil
    sign_in_as(@admin)
    Integrations::Telegram::Client.stub(:set_webhook!, ->(url:) { registered = url }) { probe("telegram_webhook") }
    assert_equal "success", response.parsed_body.dig("outcome", "tone")
    assert_equal integrations_telegram_webhook_url, registered
    assert_equal "webhook", SettingsService.get(:telegram_update_mode)
  end

  test "Telegram groups are approved, paused, resumed and removed from the card" do
    pending = TelegramChatAuthorization.create!(chat_id: "-100555", chat_title: "Book club", code_digest: TelegramChatAuthorization.digest("482913"), code_generated_at: Time.current)
    sign_in_as(@admin)
    post web_preview_api_admin_settings_telegram_chats_path, params: { code: "000000" }, headers: account_headers(@admin), as: :json
    assert_equal({ "tone" => "error", "message" => "Telegram group code is invalid or expired." }, response.parsed_body.fetch("outcome"))
    post web_preview_api_admin_settings_telegram_chats_path, params: { code: "482913" }, headers: account_headers(@admin), as: :json
    assert_equal "Telegram group authorized: Book club", response.parsed_body.dig("outcome", "message")
    assert_equal [ { "id" => pending.id.to_s, "label" => "Book club", "chat_id" => "-100555", "state" => "authorized" } ], response.parsed_body.fetch("chats")

    post web_preview_api_admin_telegram_chat_pause_path(id: pending.id), headers: account_headers(@admin), as: :json
    assert_equal "paused", response.parsed_body.dig("chats", 0, "state")
    post web_preview_api_admin_telegram_chat_resume_path(id: pending.id), headers: account_headers(@admin), as: :json
    assert_equal "authorized", response.parsed_body.dig("chats", 0, "state")
    delete web_preview_api_admin_telegram_chat_path(id: pending.id), headers: account_headers(@admin), as: :json
    assert_equal({ "tone" => "success", "message" => "Telegram group removed: Book club" }, response.parsed_body.fetch("outcome"))
    assert_equal [], response.parsed_body.fetch("chats")
    delete web_preview_api_admin_telegram_chat_path(id: pending.id), headers: account_headers(@admin), as: :json
    assert_response :not_found
  end

  test "the library card lists the platform's libraries and starts a sync only when connected" do
    sign_in_as(@admin)
    post web_preview_api_admin_settings_library_sync_path, headers: account_headers(@admin), as: :json
    assert_equal "error", response.parsed_body.dig("outcome", "tone")
    assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob)

    library = Struct.new(:id, :name, :media_type).new("lib-1", "Books", "book")
    LibraryPlatformClient.stub(:configured?, true) do
      LibraryPlatformClient.stub(:libraries, [ library ]) do
        preview_get web_preview_api_admin_settings_library_path, user: @admin
        assert_equal [ { "id" => "lib-1", "name" => "Books", "media_type" => "book" } ], response.parsed_body.fetch("libraries")
        assert_equal 0, response.parsed_body.dig("inventory", "count")
      end
      assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) do
        post web_preview_api_admin_settings_library_sync_path, headers: account_headers(@admin), as: :json
      end
      assert_equal "success", response.parsed_body.dig("outcome", "tone")
      LibraryPlatformClient.stub(:libraries, ->(*) { raise LibraryPlatformClient::Error, "offline" }) do
        preview_get web_preview_api_admin_settings_library_path, user: @admin
        assert_nil response.parsed_body.fetch("libraries")
      end
    end
  end

  test "the overview reports counts, saved health with its fix, the release, and runs both checks" do
    SystemHealth.for_service("output_paths").check_failed!(message: "Missing /ebooks")
    body = nil
    admin_get web_preview_api_admin_overview_path
    body = response.parsed_body
    assert_equal SystemHealth::SERVICES, body.fetch("services").map { |entry| entry.fetch("service") }
    output = body.fetch("services").find { |entry| entry["service"] == "output_paths" }
    assert_equal({ "service" => "output_paths", "label" => "Output paths", "status" => "down", "message" => "Missing /ebooks", "fix" => { "category" => "library", "group" => "folders", "label" => "Folder settings" } },
      output.except("checked_at"))
    assert_nil body.fetch("services").find { |entry| entry["service"] == "hardcover" }.fetch("checked_at")
    assert_equal({ "users" => User.active.count, "books" => Book.count, "active_requests" => Request.active.count, "attention_requests" => Request.needs_attention.count }, body.fetch("counts"))
    assert_equal Consumer::ServerInfo.server_version, body.dig("release", "build")

    assert_enqueued_with(job: HealthCheckJob) { post web_preview_api_admin_health_check_path, headers: account_headers(@admin), as: :json }
    assert_equal "Health check started. Results will appear shortly.", response.parsed_body.dig("outcome", "message")

    result = UpdateCheckerService::Result.new(update_available: true, current_version: "1.0.0", latest_version: "1.1.0", latest_message: nil, latest_date: nil, release_url: "https://github.com/example/releases/1.1.0")
    UpdateCheckerService.stub(:check, result) { post web_preview_api_admin_update_check_path, headers: account_headers(@admin), as: :json }
    assert_equal "Update available: 1.1.0", response.parsed_body.dig("outcome", "message")
    assert_equal({ "state" => "available", "version" => "1.1.0", "release_url" => "https://github.com/example/releases/1.1.0" }, response.parsed_body.dig("release", "latest"))
  end

  test "webhook addresses never reach the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("values" => { "discord_webhook_url" => "https://discord.example/api/webhooks/1/abc", "webhook_url" => "https://ntfy.example/t?auth=abc", "webhook_topic" => "books" })
    assert_equal({ "values" => { "discord_webhook_url" => "[FILTERED]", "webhook_url" => "[FILTERED]", "webhook_topic" => "books" } }, filtered)
  end

  test "the webhook address is write-only: only its origin is shown, blank keeps it and an explicit removal clears it" do
    SettingsService.set(:webhook_url, "https://ntfy.example/shelf?auth=webhook-secret-7781")
    body = settings_json
    assert_not_includes response.body, "webhook-secret-7781"
    assert_equal({ "input" => "secret", "configured" => true, "clearable" => true, "shown" => "https://ntfy.example", "value" => nil },
      field_json(body, :webhook_url).slice("input", "configured", "clearable", "shown", "value"))

    save_group("webhook", { webhook_url: "" })
    assert_equal [], response.parsed_body.fetch("changed")
    assert_equal "https://ntfy.example/shelf?auth=webhook-secret-7781", SettingsService.get(:webhook_url)
    assert_not_includes response.body, "webhook-secret-7781"

    SettingsService.set(:webhook_url, "https://user:pass-5512@hooks.example:8443/path?auth=x")
    assert_equal "https://hooks.example", field_json(settings_json, :webhook_url).fetch("shown")
    assert_not_includes response.body, "pass-5512"
    save_group("webhook", { webhook_url: "https://hooks.example/new" })
    assert_equal "https://hooks.example/new", SettingsService.get(:webhook_url)
    save_group("webhook", { webhook_url: nil })
    assert_equal [ "webhook_url" ], response.parsed_body.fetch("changed")
    assert_equal "", SettingsService.get(:webhook_url)
  end

  test "passwords switched off by DISABLE_AUTH show as managed by it and the stored setting is left alone" do
    with_env("DISABLE_AUTH" => "true") do
      body = settings_json
      assert_equal({ "managed_by" => "DISABLE_AUTH", "value" => true }, field_json(body, :auth_disabled).slice("managed_by", "value"))
      save_group("sign_in", { auth_disabled: "true", session_max_age_days: "14" })
      assert_equal [ "session_max_age_days" ], response.parsed_body.fetch("changed")
      assert_equal false, SettingsService.get(:auth_disabled)
    end
    body = settings_json
    assert_nil field_json(body, :auth_disabled)["managed_by"]
    assert_equal false, field_json(body, :auth_disabled).fetch("value")
  end

  test "a failed webhook test never repeats the saved address or its query" do
    address = "https://ntfy.example/shelf?auth=webhook-secret-7781"
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, address)
    sign_in_as(@admin)
    failure = OutboundNotifications::WebhookDelivery::DeliveryError.new("401 for /shelf?auth=webhook-secret-7781 (path /shelf)")
    OutboundNotifications::WebhookDelivery.stub(:deliver!, ->(**) { raise failure }) { probe("webhook") }
    assert_equal WebPreview::Admin::SettingsController::PRIVATE_ADDRESS_FAILURE.stringify_keys, response.parsed_body.fetch("outcome")
    assert_not_includes response.body, "webhook-secret-7781"

    SettingsService.set(:discord_enabled, true)
    SettingsService.set(:discord_webhook_url, "https://discord.example/api/webhooks/1/discord-secret-5512")
    echoed = OutboundNotifications::DiscordDelivery::DeliveryError.new("404 /api/webhooks/1/discord-secret-5512")
    OutboundNotifications::DiscordDelivery.stub(:deliver!, ->(**) { raise echoed }) { probe("discord") }
    assert_equal "error", response.parsed_body.dig("outcome", "tone")
    assert_not_includes response.body, "discord-secret-5512"

    OutboundNotifications::DiscordDelivery.stub(:deliver!, ->(**) { true }) { probe("discord") }
    assert_equal({ "tone" => "success", "message" => "Discord test sent successfully!" }, response.parsed_body.fetch("outcome"))
  end

  test "whitespace never replaces a write-only address, and an IPv6 address shows its whole host" do
    SettingsService.set(:webhook_url, "https://[2001:db8::1]:8443/hook?auth=x")
    assert_equal "https://[2001:db8::1]", field_json(settings_json, :webhook_url).fetch("shown")
    save_group("webhook", { webhook_url: "   " })
    assert_equal [], response.parsed_body.fetch("changed")
    save_group("webhook", { webhook_url: "\u00a0\t" })
    assert_equal [], response.parsed_body.fetch("changed")
    save_group("webhook", { webhook_url: "\u0000" })
    assert_equal [], response.parsed_body.fetch("changed")
    assert_equal "https://[2001:db8::1]:8443/hook?auth=x", SettingsService.get(:webhook_url)
  end

  test "a refused Telegram webhook registration is reported with Telegram's answer" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, SECRETS[:telegram_bot_token])
    SettingsService.set(:telegram_webhook_secret, "webhook-secret-for-telegram")
    sign_in_as(@admin)
    refuse = ->(url:) { raise Integrations::Telegram::Client::DeliveryError, "Telegram setWebhook failed: HTTPS url must be provided for webhook" }
    Integrations::Telegram::Client.stub(:set_webhook!, refuse) { probe("telegram_webhook") }
    assert_equal({ "tone" => "error", "message" => "Telegram setWebhook failed: HTTPS url must be provided for webhook" }, response.parsed_body.fetch("outcome"))
  end

  test "a card reads the other bound of a size range inside the same write transaction" do
    SettingsService.set(:ebook_max_file_size, "100 MB")
    baseline = Setting.connection.open_transactions
    seen = []
    lookup = ->(key) { seen << [ key.to_s, Setting.connection.open_transactions ]; SettingsService.get(key) }
    ServerSettings::Change.new(lookup: lookup).apply([ [ "ebook_min_file_size", "80 MB" ] ])
    assert_equal [ [ "ebook_max_file_size", baseline + 1 ] ], seen
  end

  test "old overview and settings addresses still open the preview, which then moves to Server" do
    sign_in_as(@admin)
    [ web_preview_admin_path, web_preview_admin_settings_path ].each do |path|
      get path
      assert_response :success, path
      assert_select "#shelfarr-boot"
    end
  end

  test "the overview lists no administration screen as missing from the preview" do
    admin_get web_preview_api_admin_overview_path
    assert_equal [], response.parsed_body.fetch("pending")
    indexer = settings_json.fetch("categories").flat_map { |category| category["groups"] }.find { |group| group["id"] == "indexer" }
    assert_equal ServerSettings::Probe::POSTED_KEYS, indexer.dig("probes", 0, "draft_keys")
  end

  test "the session tells every page what this account may do without exposing settings" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@member)
    preview_get web_preview_api_session_path, user: @member
    assert_equal({ "administrator" => false, "can_upload" => true, "single_sign_on" => false, "hardcover_personal_access" => false }, response.parsed_body.fetch("capabilities"))
    SettingsService.set(:allow_user_uploads, false)
    preview_get web_preview_api_session_path, user: @member
    assert_equal false, response.parsed_body.dig("capabilities", "can_upload")
  end
end
