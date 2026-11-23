# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminSetupTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  PASSWORD = "Password123!"
  SETUP_KEYS = %w[
    setup_wizard_completed indexer_provider prowlarr_url prowlarr_api_key
    library_platform audiobookshelf_url audiobookshelf_api_key
    audiobookshelf_audiobook_library_id audiobookshelf_ebook_library_id
    audiobook_output_path ebook_output_path download_local_path download_remote_path
    immediate_search_enabled auto_select_enabled auto_select_confidence_threshold auto_select_min_seeders
  ].freeze
  LIBRARIES = {
    "libraries" => [
      { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/audiobooks" } ] },
      { "id" => "lib-ebooks", "name" => "Ebooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/ebooks" } ] }
    ]
  }.freeze

  setup do
    @member = users(:one)
    @admin = users(:two)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    reset_client_caches
    Setting.where(key: SETUP_KEYS).delete_all
    DownloadClient.delete_all
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    reset_client_caches
  end

  def setup_state(step = nil, user: @admin)
    sign_in_as(user)
    preview_get web_preview_api_admin_setup_path(step: step), user: user
    response.parsed_body
  end

  def save_step(step, values, user: @admin)
    put web_preview_api_admin_setup_step_path(step: step), params: { values: values }, headers: account_headers(user), as: :json
    response.parsed_body
  end

  def skip_step(step, exit_setup: false, user: @admin)
    post web_preview_api_admin_setup_skip_path, params: { step: step, exit: exit_setup }, headers: account_headers(user), as: :json
    response.parsed_body
  end

  def card(body, id)
    body.fetch("cards").find { |entry| entry.fetch("id") == id }
  end

  def field(body, card_id, key)
    card(body, card_id).fetch("fields").find { |entry| entry.fetch("key") == key }
  end

  def write_requests
    [
      [ :put, web_preview_api_admin_setup_step_path(step: "prowlarr"), { values: { url: "http://prowlarr:9696", api_key: "typed" } } ],
      [ :post, web_preview_api_admin_setup_skip_path, { step: "prowlarr", exit: true } ],
      [ :post, web_preview_api_admin_setup_restart_path, {} ]
    ]
  end

  def stub_audiobookshelf
    stub_request(:get, "http://audiobookshelf:13378/api/libraries")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: LIBRARIES.to_json)
  end

  test "with the preview off, or for someone not on its list, setup answers not found and changes nothing" do
    sign_in_as(@admin)
    with_env(WebPreview::Access::VARIABLE => nil) do
      get web_preview_server_setup_path
      assert_response :not_found
      preview_get web_preview_api_admin_setup_path, user: @admin
      assert_response :not_found
      write_requests.each do |method, path, body|
        public_send(method, path, params: body, headers: account_headers(@admin), as: :json)
        assert_response :not_found, path
      end
    end

    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      preview_get web_preview_api_admin_setup_path, user: @admin
      assert_response :not_found
    end
    assert_nil Setting.find_by(key: "setup_wizard_completed")
    assert_nil Setting.find_by(key: "prowlarr_url")
  end

  test "a member gets not found from every setup read and write and nothing changes" do
    sign_in_as(@member)
    preview_get web_preview_api_admin_setup_path, user: @member
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.fetch("error")
    write_requests.each do |method, path, body|
      public_send(method, path, params: body, headers: account_headers(@member), as: :json)
      assert_response :not_found, path
    end
    assert_nil Setting.find_by(key: "setup_wizard_completed")
    assert_nil Setting.find_by(key: "prowlarr_url")
  end

  test "an administrator who loses the role mid-way is refused the next step" do
    assert_equal "prowlarr", setup_state.fetch("step")

    @admin.update!(role: :user)
    save_step("prowlarr", { url: "http://prowlarr:9696", api_key: "typed" })

    assert_response :not_found
    assert_nil Setting.find_by(key: "prowlarr_url")
  ensure
    @admin.update!(role: :admin)
  end

  test "signed out or for another account, setup is refused before it reads or writes" do
    preview_get web_preview_api_admin_setup_path, user: @admin
    assert_response :unauthorized
    assert_equal "signed_out", response.parsed_body.fetch("error")

    sign_in_as(@admin)
    write_requests.each do |method, path, body|
      public_send(method, path, params: body, headers: account_headers(@member), as: :json)
      assert_response :unauthorized, path
      assert_equal "account_changed", response.parsed_body.fetch("error")
    end
    assert_nil Setting.find_by(key: "setup_wizard_completed")
  end

  test "setup writes need the page's CSRF token" do
    sign_in_as(@admin)
    with_forgery_protection do
      write_requests.each do |method, path, body|
        public_send(method, path, params: body, headers: account_headers(@admin), as: :json)
        assert_response :unprocessable_entity, path
        assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      end

      token = csrf_token
      post web_preview_api_admin_setup_restart_path, params: {}, headers: account_headers(@admin).merge("X-CSRF-Token" => token), as: :json
      assert_response :success
    end
  end

  test "the first step lists every step, keeps a saved key write-only and never sends it" do
    SettingsService.set(:prowlarr_url, "http://prowlarr:9696")
    SettingsService.set(:prowlarr_api_key, "saved-prowlarr-key-5521")

    body = setup_state

    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal @admin.id.to_s, body.fetch("account")
    assert_equal SetupWizard::STEPS, body.fetch("steps").map { |entry| entry.fetch("id") }
    assert_equal [ "Prowlarr", "qBittorrent", "Folders", "Audiobookshelf", "Search" ], body.fetch("steps").map { |entry| entry.fetch("label") }
    assert_nil body.fetch("previous")
    assert_equal false, body.fetch("last")
    assert_equal false, body.fetch("completed")
    assert_equal({ "key" => "url", "label" => "Prowlarr address", "description" => "Use the Docker service name or a LAN IP. localhost is Shelfarr's own container.",
      "input" => "url", "value" => "http://prowlarr:9696", "placeholder" => "http://prowlarr:9696" }, field(body, "prowlarr", "url"))
    assert_equal({ "key" => "api_key", "label" => "Prowlarr API key", "description" => "In Prowlarr, open Settings › General and copy the API key.",
      "input" => "secret", "value" => nil, "configured" => true }, field(body, "prowlarr", "api_key"))
    assert_not_includes response.body, "saved-prowlarr-key-5521"
    assert_equal "prowlarr", setup_state("not-a-step").fetch("step")
  end

  test "prowlarr saves exactly as the classic step does and a refused connection saves nothing" do
    VCR.turned_off do
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer").to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
      sign_in_as(@admin)

      body = save_step("prowlarr", { url: "http://prowlarr:9696", api_key: "prowlarr-key" })

      assert_response :success
      assert_equal({ "tone" => "success", "message" => "Prowlarr connected." }, body.fetch("outcome"))
      assert_nil body.fetch("alert")
      assert_equal false, body.fetch("completed")
      assert_equal "qbittorrent", body.dig("setup", "step")
      assert_equal "prowlarr", body.dig("setup", "previous")
      assert_equal [ "prowlarr", "http://prowlarr:9696", "prowlarr-key" ], %i[indexer_provider prowlarr_url prowlarr_api_key].map { |key| SettingsService.get(key) }

      Setting.where(key: %w[indexer_provider prowlarr_url prowlarr_api_key]).delete_all
      stub_request(:get, "http://127.0.0.1:9696/api/v1/indexer").to_raise(Errno::ECONNREFUSED.new("Connection refused - connect(2)"))

      body = save_step("prowlarr", { url: "http://127.0.0.1:9696", api_key: "typed-key" })

      assert_response :unprocessable_entity
      assert_equal({ "account" => @admin.id.to_s, "error" => "setup_rejected",
        "message" => "Could not connect to Prowlarr: Connection refused. #{ConnectionErrorClassifier::LOCALHOST_HINT}" }, body)
      assert_not SettingsService.active_indexer_configured?
    end
  end

  test "a blank key keeps the saved one, and leaving a step part-way keeps what was saved before" do
    VCR.turned_off do
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer").to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
      SettingsService.set(:prowlarr_api_key, "saved-key")
      sign_in_as(@admin)

      save_step("prowlarr", { url: "http://prowlarr:9696", api_key: "" })
      assert_response :success
      assert_equal "saved-key", SettingsService.get(:prowlarr_api_key)

      save_step("prowlarr", { url: "", api_key: "" })
      assert_response :unprocessable_entity
      assert_equal "Enter the Prowlarr URL and API key.", response.parsed_body.fetch("message")

      body = setup_state("prowlarr")
      assert_equal "http://prowlarr:9696", field(body, "prowlarr", "url").fetch("value")
      assert_equal true, field(body, "prowlarr", "api_key").fetch("configured")
    end
  end

  test "qbittorrent creates one client, a rerun updates it and a bad key creates nothing" do
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")
      sign_in_as(@admin)

      assert_no_difference "DownloadClient.count" do
        save_step("qbittorrent", { url: "http://qbittorrent:8080", username: "", password: "", api_key: "not-a-key", category: "" })
      end
      assert_response :unprocessable_entity
      assert_equal "qBittorrent API key must start with qbt_ and contain 28 characters after the prefix.", response.parsed_body.fetch("message")

      assert_difference "DownloadClient.count", 1 do
        save_step("qbittorrent", { url: "http://qbittorrent:8080", username: "admin", password: "secret-pass-1", api_key: "", category: "" })
      end
      assert_equal "folders", response.parsed_body.dig("setup", "step")

      body = setup_state("qbittorrent")
      assert_equal "admin", field(body, "qbittorrent", "username").fetch("value")
      assert_equal true, field(body, "qbittorrent", "password").fetch("configured")
      assert_equal false, field(body, "qbittorrent", "api_key").fetch("configured")
      assert_not_includes response.body, "secret-pass-1"

      assert_no_difference "DownloadClient.count" do
        save_step("qbittorrent", { url: "http://qbittorrent:8080", username: "admin", password: "", api_key: "", category: "" })
      end
      assert_equal "secret-pass-1", DownloadClient.qbittorrent.sole.password
    end
  end

  test "folders save and pass on a path warning without blocking the next step" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "", enabled: true)
    Dir.mktmpdir do |local_path|
      VCR.turned_off do
        stub_qbittorrent_connection("http://qbittorrent:8080")
        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => "/mnt/torrents" }.to_json)
        sign_in_as(@admin)

        body = save_step("folders", {
          audiobook_output_path: "#{local_path}/audiobooks", ebook_output_path: "#{local_path}/ebooks",
          download_local_path: local_path, download_remote_path: ""
        })

        assert_response :success
        assert_equal({ "tone" => "success", "message" => "Folders saved." }, body.fetch("outcome"))
        assert_equal "qBittorrent saves to /mnt/torrents, which is not inside #{local_path} or does not exist in this container.", body.fetch("alert")
        assert_equal "audiobookshelf", body.dig("setup", "step")
        assert_equal local_path, SettingsService.get(:download_local_path)
        assert_equal "", SettingsService.get(:download_remote_path)

        state = setup_state("folders")
        assert_equal [], state.fetch("warnings")
        assert_equal "/mnt/torrents", field(state, "folders", "download_remote_path").fetch("value")
      end
    end
  end

  test "audiobookshelf stays on its step after connecting, suggests libraries once, then saves the choice" do
    VCR.turned_off do
      stub_audiobookshelf
      sign_in_as(@admin)

      assert_equal [ "audiobookshelf_connection" ], setup_state("audiobookshelf").fetch("cards").map { |entry| entry.fetch("id") }

      body = save_step("audiobookshelf", { url: "http://audiobookshelf:13378", api_key: "abs-token", phase: "connection" })

      assert_response :success
      assert_equal "Audiobookshelf connected. Choose the libraries Shelfarr should scan.", body.dig("outcome", "message")
      state = body.fetch("setup")
      assert_equal "audiobookshelf", state.fetch("step")
      assert_equal [ "audiobookshelf_libraries", "audiobookshelf_connection" ], state.fetch("cards").map { |entry| entry.fetch("id") }
      libraries = card(state, "audiobookshelf_libraries")
      assert_equal "libraries", libraries.fetch("phase")
      assert_equal [ { "id" => "lib-audio", "name" => "Audiobooks", "media_type" => "book" }, { "id" => "lib-ebooks", "name" => "Ebooks", "media_type" => "book" } ], libraries.fetch("libraries")
      assert_equal "Not now", field(state, "audiobookshelf_libraries", "audiobook_library_id").fetch("placeholder")
      assert_equal true, card(state, "audiobookshelf_connection").fetch("collapsed")
      assert_not_includes response.body, "abs-token"

      assert_enqueued_jobs 1, only: AudiobookshelfLibrarySyncJob do
        body = save_step("audiobookshelf", { phase: "libraries", audiobook_library_id: "lib-audio", ebook_library_id: "" })
      end
      assert_equal "search", body.dig("setup", "step")
      assert_equal "lib-audio", SettingsService.get(:audiobookshelf_audiobook_library_id)
      assert_equal "", SettingsService.get(:audiobookshelf_ebook_library_id)

      state = setup_state("audiobookshelf")
      assert_equal "", field(state, "audiobookshelf_libraries", "ebook_library_id").fetch("value")
    end
  end

  test "finishing completes setup with the classic search choices" do
    sign_in_as(@admin)

    state = setup_state("search")
    assert_equal true, state.fetch("last")
    assert_equal [ true, false ], %w[immediate_search_enabled auto_select_enabled].map { |key| field(state, "search", key).fetch("value") }

    body = save_step("search", { immediate_search_enabled: false, auto_select_enabled: true })

    assert_response :success
    assert_equal({ "account" => @admin.id.to_s, "outcome" => { "tone" => "success", "message" => "Setup complete." }, "alert" => nil, "completed" => true, "setup" => nil }, body)
    assert_equal [ false, true, true ], %i[immediate_search_enabled auto_select_enabled setup_wizard_completed].map { |key| SettingsService.get(key) }
  end

  test "skip moves on without saving, skip setup completes it, and restart opens it again" do
    sign_in_as(@admin)

    body = skip_step("prowlarr")
    assert_equal({ false => "qbittorrent" }, { body.fetch("completed") => body.dig("setup", "step") })
    assert_not SettingsService.active_indexer_configured?
    assert_equal false, SettingsService.get(:setup_wizard_completed)

    body = skip_step("folders", exit_setup: true)
    assert_equal({ "account" => @admin.id.to_s, "completed" => true, "setup" => nil }, body)
    assert_equal true, SettingsService.get(:setup_wizard_completed)

    post web_preview_api_admin_setup_restart_path, params: {}, headers: account_headers(@admin), as: :json
    assert_response :success
    assert_equal [ false, "prowlarr" ], [ response.parsed_body.fetch("completed"), response.parsed_body.dig("setup", "step") ]
    assert_equal false, SettingsService.get(:setup_wizard_completed)

    skip_step("search")
    assert_equal true, response.parsed_body.fetch("completed")
  end

  test "an unknown step or a malformed body is refused without saving" do
    sign_in_as(@admin)

    save_step("bogus", { url: "http://prowlarr:9696", api_key: "typed" })
    assert_response :not_found
    skip_step("bogus")
    assert_response :not_found
    put web_preview_api_admin_setup_step_path(step: "prowlarr"), params: { values: "url" }, headers: account_headers(@admin), as: :json
    assert_response :bad_request
    assert_nil Setting.find_by(key: "prowlarr_url")
    assert_equal false, SettingsService.get(:setup_wizard_completed)
  end

  test "a step's write needs every one of its values, each as text or a switch, and otherwise saves nothing" do
    SettingsService.set(:audiobook_output_path, "/books/audio")
    SettingsService.set(:ebook_output_path, "/books/ebooks")
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:auto_select_enabled, true)
    folders = { audiobook_output_path: "/a", ebook_output_path: "/e", download_local_path: "/d", download_remote_path: "" }
    sign_in_as(@admin)

    [
      [ "folders", folders.except(:ebook_output_path) ],
      [ "folders", folders.merge(audiobook_output_path: { nested: "/a" }) ],
      [ "folders", folders.merge(immediate_search_enabled: true) ],
      [ "search", {} ],
      [ "search", { immediate_search_enabled: "true", auto_select_enabled: false } ],
      [ "search", { immediate_search_enabled: true } ],
      [ "audiobookshelf", { phase: "elsewhere", url: "http://abs", api_key: "" } ],
      [ "audiobookshelf", { phase: "libraries", url: "http://abs", api_key: "" } ],
      [ "prowlarr", { url: [ "http://prowlarr:9696" ], api_key: "" } ]
    ].each do |step, values|
      save_step(step, values)
      assert_response :bad_request, "#{step} #{values}"
      assert_equal "invalid_request", response.parsed_body.fetch("error")
    end
    put web_preview_api_admin_setup_step_path(step: "search"), params: {}, headers: account_headers(@admin), as: :json
    assert_response :bad_request

    assert_equal [ "/books/audio", "/books/ebooks", false, true, false ],
      %i[audiobook_output_path ebook_output_path immediate_search_enabled auto_select_enabled setup_wizard_completed].map { |key| SettingsService.get(key) }
  end

  test "a saved address with sign-in details stays on the server, blank keeps it, and errors never repeat a typed secret" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbuser:qb-pass-7781@qbittorrent:8080", username: "admin", password: "secret", category: "", enabled: true)
    SettingsService.set(:audiobookshelf_url, "http://audiobookshelf:13378/?access_token=abs-query-6620")
    SettingsService.set(:audiobookshelf_api_key, "abs-token")
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")
      stub_request(:get, %r{\Ahttp://audiobookshelf:13378/api/libraries})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: LIBRARIES.to_json)
      sign_in_as(@admin)

      state = setup_state("qbittorrent")
      assert_equal({ "key" => "url", "label" => "qBittorrent address",
        "description" => "The address of the qBittorrent web interface, as Shelfarr's container reaches it. The saved address includes sign-in details.",
        "input" => "secret", "value" => nil, "configured" => true }, field(state, "qbittorrent", "url"))
      assert_not_includes response.body, "qb-pass-7781"

      state = setup_state("audiobookshelf")
      assert_equal "Connected to http://audiobookshelf:13378. Choose the libraries Shelfarr should scan.", card(state, "audiobookshelf_libraries").fetch("summary")
      assert_equal "secret", field(state, "audiobookshelf_connection", "url").fetch("input")
      assert_not_includes response.body, "abs-query-6620"

      save_step("qbittorrent", { url: "", username: "admin", password: "", api_key: "", category: "" })
      assert_response :success
      assert_equal "http://qbuser:qb-pass-7781@qbittorrent:8080", DownloadClient.qbittorrent.sole.url
      assert_not_includes response.body, "qb-pass-7781"
    end

    [
      "http://someone:typed-pass-5521@bad host",
      "http://someone:typed pass 5521@audiobookshelf:13378",
      "  http://bad host/?access_token=typed-pass-5521  ",
      "  http://someone:typed-pass-5521@bad host/#{"x" * 600}  ",
      "http://bad host/#{"y" * 480}?access_token=typed-pass-5521"
    ].each do |address|
      save_step("audiobookshelf", { phase: "connection", url: address, api_key: "typed-token-3390" })
      assert_response :unprocessable_entity
      assert_match(/\ACould not connect to Audiobookshelf: /, response.parsed_body.fetch("message"))
      assert_no_match(/typed.pass.5521|typed-token-3390|abs-query-6620/, response.body)
    end
    assert_equal "http://audiobookshelf:13378/?access_token=abs-query-6620", SettingsService.get(:audiobookshelf_url)
  end

  test "skip needs a plain true or false for leaving setup" do
    sign_in_as(@admin)
    [ { "choice" => false }, "yes", nil ].each do |value|
      post web_preview_api_admin_setup_skip_path, params: { step: "prowlarr", exit: value }, headers: account_headers(@admin), as: :json
      assert_response :bad_request, value.inspect
    end
    assert_equal false, SettingsService.get(:setup_wizard_completed)
  end

  test "a classic setup form submitted by a preview administrator carries on in the classic pages with its notice and suggestions" do
    SettingsService.set(:audiobook_output_path, "/audiobooks")
    SettingsService.set(:ebook_output_path, "/ebooks")
    VCR.turned_off do
      stub_audiobookshelf
      sign_in_as(@admin)

      patch admin_setup_wizard_path(step: "audiobookshelf"), params: { wizard: { url: "http://audiobookshelf:13378", api_key: "abs-token" } }
      assert_redirected_to admin_setup_wizard_path(step: "audiobookshelf")
      follow_redirect!

      assert_response :success
      assert_select "select[name='wizard[audiobook_library_id]'] option[selected][value='lib-audio']"
      assert_select "select[name='wizard[ebook_library_id]'] option[selected][value='lib-ebooks']"
      assert_includes response.body, "Audiobookshelf connected. Choose the libraries Shelfarr should scan."
    end
  end

  test "the old setup address takes a preview administrator to the same step here, and stays classic for everyone else" do
    sign_in_as(@admin)
    get admin_setup_wizard_path(step: "folders")
    assert_redirected_to web_preview_server_setup_path(step: "folders")
    get admin_setup_wizard_path(step: "bogus")
    assert_redirected_to web_preview_server_setup_path

    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      get admin_setup_wizard_path(step: "folders")
      assert_response :success
      assert_select "h2", "Folders"
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      get admin_setup_wizard_path
      assert_response :success
    end
    WarmEntry.stub(:stylesheet_built?, false) do
      get admin_setup_wizard_path
      assert_response :success
      assert_select "h1", "Set up Shelfarr"
    end

    post skip_admin_setup_wizard_path(step: "prowlarr")
    assert_redirected_to admin_setup_wizard_path(step: "qbittorrent")
    follow_redirect!
    assert_redirected_to web_preview_server_setup_path(step: "qbittorrent")

    get "/admin/setup_wizard?step=folders", env: { "SCRIPT_NAME" => "/shelf" }
    assert_redirected_to "http://www.example.com/shelf/preview/server/setup?step=folders"
  end

  test "an existing setup can run again here and keeps the saved settings" do
    SettingsService.set(:setup_wizard_completed, true)
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "http://prowlarr:9696")
    SettingsService.set(:prowlarr_api_key, "saved-key")
    DownloadClient.create!(name: "Existing", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", enabled: true)
    sign_in_as(@admin)

    post web_preview_api_admin_setup_restart_path, params: {}, headers: account_headers(@admin), as: :json

    state = response.parsed_body.fetch("setup")
    assert_equal "http://prowlarr:9696", field(state, "prowlarr", "url").fetch("value")
    assert_equal "http://qbittorrent:8080", field(setup_state("qbittorrent"), "qbittorrent", "url").fetch("value")
    assert_equal "saved-key", SettingsService.get(:prowlarr_api_key)
    assert_equal 1, DownloadClient.count
  end

  test "the overview asks for setup only while nothing is configured or finished" do
    sign_in_as(@admin)
    preview_get web_preview_api_admin_overview_path, user: @admin
    assert_equal({ "pending" => true, "completed" => false }, response.parsed_body.fetch("setup"))

    SetupWizard.complete!
    preview_get web_preview_api_admin_overview_path, user: @admin
    assert_equal({ "pending" => false, "completed" => true }, response.parsed_body.fetch("setup"))
  end

  test "the setup page and the old setup address open the preview" do
    sign_in_as(@admin)
    [ web_preview_server_setup_path, web_preview_server_setup_path(step: "folders"), web_preview_admin_setup_wizard_path(step: "folders") ].each do |path|
      get path
      assert_response :success, path
      assert_select "#shelfarr-boot"
    end
  end

  test "the first administrator goes on to setup in the preview only when the preview lets them in" do
    User.find_each(&:destroy!)
    with_preview_for("first") do
      post sign_up_path, params: { user: { name: "First", username: "first", password: PASSWORD, password_confirmation: PASSWORD } }
      assert_redirected_to web_preview_server_setup_path
      follow_redirect!
      assert_response :success
      assert_select "#shelfarr-boot"
    end
    assert User.find_by!(username: "first").admin?

    User.find_each(&:destroy!)
    with_preview_for("someone-else") do
      post sign_up_path, params: { user: { name: "Second", username: "second", password: PASSWORD, password_confirmation: PASSWORD } }
    end
    assert_redirected_to admin_setup_wizard_path

    User.find_each(&:destroy!)
    with_env(WebPreview::Access::VARIABLE => nil) do
      post sign_up_path, params: { user: { name: "Third", username: "third", password: PASSWORD, password_confirmation: PASSWORD } }
    end
    assert_redirected_to admin_setup_wizard_path
  end

  test "without the built stylesheet the first administrator stays on the classic setup" do
    User.find_each(&:destroy!)

    WarmEntry.stub(:stylesheet_built?, false) do
      with_preview_for("first") do
        post sign_up_path, params: { user: { name: "First", username: "first", password: PASSWORD, password_confirmation: PASSWORD } }
      end
    end

    assert_redirected_to admin_setup_wizard_path
  end

  test "under a subpath the first administrator lands on the setup page below it" do
    User.find_each(&:destroy!)

    with_preview_for("first") do
      post sign_up_path, params: { user: { name: "First", username: "first", password: PASSWORD, password_confirmation: PASSWORD } }, env: { "SCRIPT_NAME" => "/shelf" }
    end

    assert_redirected_to "http://www.example.com/shelf/preview/server/setup"
  end

  private

  PreviewFor = Struct.new(:username) do
    def configured? = true
    def allows?(user) = user&.username == username
  end

  def with_preview_for(username, &block)
    WebPreview::Access.stub(:current, PreviewFor.new(username), &block)
  end

  def reset_client_caches
    LibraryPlatformClient.reset_connections!
    IndexerClient.reset_all_connections!
    Thread.current[:qbittorrent_sessions] = {}
  end
end
