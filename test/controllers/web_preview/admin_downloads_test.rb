# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminDownloadsTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  PASSWORD = "client-password-4471"
  API_KEY = "qbt_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  REPLACEMENT_API_KEY = "qbt_bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  SAB_KEY = "sabnzbd-key-90210"

  Result = Struct.new(:source, :indexer, :download_type, keyword_init: true) do
    def from_indexer?
      true
    end

    def from_jackett?
      source == SearchResult::SOURCE_JACKETT
    end

    def from_newznab?
      source == SearchResult::SOURCE_NEWZNAB
    end
  end

  setup do
    @member = users(:one)
    @admin = users(:two)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    Thread.current[:qbittorrent_sessions] = {}
    DownloadRoutingRule.delete_all
    DownloadClient.delete_all
    SystemHealth.where(service: "download_client").delete_all
    @qbit = DownloadClient.create!(name: "Home qBittorrent", client_type: "qbittorrent", url: "http://qbit.test:8080", username: "admin", password: PASSWORD, api_key: API_KEY, priority: 0)
    @second = DownloadClient.create!(name: "Seedbox qBittorrent", client_type: "qbittorrent", url: "http://seedbox.test:8080", username: "admin", priority: 1)
    @sab = DownloadClient.create!(name: "SABnzbd", client_type: "sabnzbd", url: "http://sab.test:8085", api_key: SAB_KEY, priority: 0)
    @rule = DownloadRoutingRule.create!(provider: "prowlarr", indexer_name: "MyAnonaMouse", download_type: "torrent", download_client: @second)
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def downloads_json(user: @admin)
    sign_in_as(user)
    preview_get web_preview_api_admin_downloads_path, user: user
    response.parsed_body
  end

  def write(verb, path, params = {}, user: @admin)
    send(verb, path, params: params, headers: account_headers(user), as: :json)
  end

  def neighbour(client, direction)
    peers = DownloadClient.where(client_type: client.reload.client_type).order(priority: :asc).to_a
    index = peers.index(client)
    target = direction.to_s == "up" ? index - 1 : index + 1
    target.between?(0, peers.length - 1) ? peers[target].id.to_s : "999999"
  end

  def version(record)
    WebPreview::DownloadManagement.version(record.reload)
  end

  def client_json(body, client)
    body.fetch("clients").find { |entry| entry.fetch("id") == client.id.to_s }
  end

  def error_messages
    response.parsed_body.fetch("errors").map { |error| error.fetch("message") }
  end

  def write_paths
    [
      [ :post, web_preview_api_admin_download_clients_path, { client: { name: "New", client_type: "deluge", url: "http://deluge.test:8112" } } ],
      [ :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { name: "Renamed" } } ],
      [ :delete, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), rules: [] } ],
      [ :post, web_preview_api_admin_download_client_test_path(id: @qbit.id), {} ],
      [ :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, "up"), direction: "up" } ],
      [ :post, web_preview_api_admin_download_rules_path, { rule: { provider: "jackett", indexer_name: "Books", download_type: "torrent", download_client_id: @qbit.id.to_s } } ],
      [ :put, web_preview_api_admin_download_rule_path(id: @rule.id), { version: version(@rule), rule: { indexer_name: "Changed" } } ],
      [ :delete, web_preview_api_admin_download_rule_path(id: @rule.id), { version: version(@rule) } ]
    ]
  end

  def snapshot
    [ DownloadClient.order(:id).map { |client| client.attributes.except("updated_at", "created_at") }, DownloadRoutingRule.order(:id).map(&:attributes) ]
  end

  test "with the preview switched off, for a member, signed out or for another account, no download read or write gets through" do
    before = snapshot
    with_env(WebPreview::Access::VARIABLE => "") do
      sign_in_as(@admin)
      preview_get web_preview_api_admin_downloads_path, user: @admin
      assert_response :not_found
      write_paths.each do |verb, path, params|
        write(verb, path, params)
        assert_response :not_found, path
      end
    end

    sign_in_as(@member)
    preview_get web_preview_api_admin_downloads_path, user: @member
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
    assert_no_enqueued_jobs do
      write_paths.each do |verb, path, params|
        write(verb, path, params, user: @member)
        assert_response :not_found, path
      end
    end

    sign_in_as(@admin)
    write_paths.each do |verb, path, params|
      write(verb, path, params, user: @member)
      assert_response :unauthorized, path
      assert_equal "account_changed", response.parsed_body.fetch("error")
    end

    delete session_path
    preview_get web_preview_api_admin_downloads_path, user: @admin
    assert_response :unauthorized
    write_paths.each do |verb, path, params|
      write(verb, path, params)
      assert_response :unauthorized, path
    end
    assert_equal before, snapshot
  end

  test "every download write needs the page's CSRF token" do
    before = snapshot
    sign_in_as(@admin)
    with_forgery_protection do
      write_paths.each do |verb, path, params|
        write(verb, path, params)
        assert_response :unprocessable_entity, path
        assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      end
      assert_equal before, snapshot

      token = csrf_token
      put web_preview_api_admin_download_client_path(id: @qbit.id), params: { version: version(@qbit), client: { name: "Renamed" } },
        headers: account_headers(@admin).merge("X-CSRF-Token" => token), as: :json
      assert_response :success
    end
    assert_equal "Renamed", @qbit.reload.name
  end

  test "the listing shows clients, rules and health with saved secrets only as flags" do
    SystemHealth.for_service("download_client").check_failed!(message: "All clients failed: Home qBittorrent (#{PASSWORD})")
    body = downloads_json
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    [ PASSWORD, API_KEY, SAB_KEY ].each { |secret| assert_not_includes response.body, secret }

    assert_equal [ "Home qBittorrent", "Seedbox qBittorrent", "SABnzbd" ], body.fetch("clients").map { |client| client.fetch("name") }
    assert_equal({
      "id" => @qbit.id.to_s, "version" => version(@qbit), "name" => "Home qBittorrent", "client_type" => "qbittorrent", "kind" => "torrent",
      "url" => "http://qbit.test:8080", "url_hidden" => false, "username" => "admin", "category" => "", "download_path" => "", "enabled" => true, "priority" => 0,
      "torrent_verification_max_attempts" => 10, "torrent_verification_wait_time" => 2, "password_saved" => true, "api_key_saved" => true, "rule_count" => 0, "rule_ids" => []
    }, client_json(body, @qbit))
    assert_equal [ false, false ], client_json(body, @second).values_at("password_saved", "api_key_saved")
    assert_equal [ 1, [ @rule.id.to_s ] ], client_json(body, @second).values_at("rule_count", "rule_ids")
    assert_equal "usenet", client_json(body, @sab).fetch("kind")

    assert_equal [ {
      "id" => @rule.id.to_s, "version" => version(@rule), "provider" => "prowlarr", "provider_label" => "Prowlarr", "indexer_name" => "MyAnonaMouse",
      "download_type" => "torrent", "client_id" => @second.id.to_s, "client_name" => "Seedbox qBittorrent", "client_enabled" => true, "client_kind" => "torrent", "enabled" => true
    } ], body.fetch("rules")

    types = body.fetch("client_types").index_by { |type| type.fetch("value") }
    assert_equal DownloadClient.client_types.keys, types.keys
    assert_equal({ "value" => "qbittorrent", "label" => "qBittorrent", "kind" => "torrent", "authentication" => true, "api_key" => true, "verification" => true }, types.fetch("qbittorrent"))
    assert_equal({ "value" => "sabnzbd", "label" => "SABnzbd", "kind" => "usenet", "authentication" => false, "api_key" => true, "verification" => false }, types.fetch("sabnzbd"))
    assert_equal [ false, false ], types.fetch("decypharr").values_at("api_key", "verification")
    assert_equal DownloadRoutingRule::PROVIDERS.keys, body.fetch("providers").map { |provider| provider.fetch("value") }
    assert_equal({ "client_type" => "qbittorrent", "enabled" => true, "torrent_verification_max_attempts" => 10, "torrent_verification_wait_time" => 2 }, body.fetch("defaults"))

    health = body.fetch("health")
    assert_equal "down", health.fetch("status")
    assert_equal "No enabled client answered the last check. Test each client to see why.", health.fetch("message")
  end

  test "adding a client takes the next place for its type, checks health and starts the monitor, like the classic form" do
    sign_in_as(@admin)
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbit.test:8080")
      stub_qbittorrent_connection("http://seedbox.test:8080")
      stub_qbittorrent_connection("http://third.test:8080")
      stub_request(:get, %r{\Ahttp://sab\.test:8085/api}).to_return(status: 200, body: { categories: [ "*" ] }.to_json, headers: { "Content-Type" => "application/json" })
      write :post, web_preview_api_admin_download_clients_path, { client: {
        name: "Third", client_type: "qbittorrent", url: " http://third.test:8080 ", username: "admin", password: "third-secret-1", category: "books",
        download_path: "/downloads/books", enabled: true, torrent_verification_max_attempts: "12", torrent_verification_wait_time: 3, clear_api_key: "1"
      } }
    end
    assert_response :created
    created = DownloadClient.find_by!(name: "Third")
    assert_equal created.id.to_s, response.parsed_body.fetch("created")
    assert_equal [ 2, "http://third.test:8080", "third-secret-1", "books", "/downloads/books", 12, 3, true ],
      created.attributes.values_at("priority", "url").push(created.password, created.category, created.download_path, created.torrent_verification_max_attempts, created.torrent_verification_wait_time, created.enabled)
    assert_equal({ "tone" => "success", "message" => "Download client “Third” added." }, response.parsed_body.fetch("outcome"))
    assert_not_includes response.body, "third-secret-1"
    assert SystemHealth.for_service("download_client").last_check_at.present?
  end

  test "a client the classic form refuses is refused here with the same messages and nothing is written" do
    attempts = [
      { name: "", client_type: "qbittorrent", url: "http://x.test" },
      { name: "Home qBittorrent", client_type: "qbittorrent", url: "http://x.test" },
      { name: "Bad address", client_type: "qbittorrent", url: "ftp://x.test" },
      { name: "Bad key", client_type: "qbittorrent", url: "http://x.test", api_key: "nope" },
      { name: "Bad attempts", client_type: "qbittorrent", url: "http://x.test", torrent_verification_max_attempts: "0" },
      { name: "Bad wait", client_type: "qbittorrent", url: "http://x.test", torrent_verification_wait_time: "soon" }
    ]
    sign_in_as(@admin)
    attempts.each do |attributes|
      classic = assert_no_difference -> { DownloadClient.count } do
        post admin_download_clients_url, params: { download_client: attributes }
        assert_response :unprocessable_entity
        css_select("ul.list-disc li").map { |item| item.text.strip }
      end
      assert_no_difference -> { DownloadClient.count } do
        write :post, web_preview_api_admin_download_clients_path, { client: attributes }
      end
      assert_response :unprocessable_entity
      assert_equal "invalid_record", response.parsed_body.fetch("error")
      assert_equal classic, error_messages, attributes.inspect
    end

    write :post, web_preview_api_admin_download_clients_path, { client: { name: "Odd", client_type: "ftp", url: "http://x.test" } }
    assert_response :unprocessable_entity
    assert_equal [ { "field" => "client_type", "message" => "Client type is not a supported client type" } ], response.parsed_body.fetch("errors")

    write :post, web_preview_api_admin_download_clients_path, { client: { name: [ "Odd" ], client_type: "deluge", url: "http://x.test" } }
    assert_response :bad_request
    write :post, web_preview_api_admin_download_clients_path, { name: "Unwrapped" }
    assert_response :bad_request
    assert_equal 3, DownloadClient.count
  end

  test "saving a client keeps blank secrets, replaces typed ones and clears the API key only when asked" do
    sign_in_as(@admin)
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbit.test:8080")
      stub_qbittorrent_connection("http://seedbox.test:8080")
      stub_request(:get, %r{\Ahttp://sab\.test:8085/api}).to_return(status: 200, body: { categories: [ "*" ] }.to_json, headers: { "Content-Type" => "application/json" })

      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { name: "Home", password: "", api_key: "" } }
      assert_response :success
      assert_equal [ "Home", PASSWORD, API_KEY ], [ @qbit.reload.name, @qbit.password, @qbit.api_key ]
      assert_equal "Download client “Home” saved.", response.parsed_body.dig("outcome", "message")

      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { password: "new-password-2", api_key: REPLACEMENT_API_KEY } }
      assert_equal [ "new-password-2", REPLACEMENT_API_KEY ], [ @qbit.reload.password, @qbit.api_key ]

      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { api_key: "", clear_api_key: "1" } }
      assert_nil @qbit.reload.api_key
      assert_equal false, client_json(response.parsed_body, @qbit).fetch("api_key_saved")

      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { name: "Home" } }
      assert_equal "There were no changes to save.", response.parsed_body.dig("outcome", "message")
    end
  end

  test "a refused save keeps the saved secrets and says a typed API key must be entered again" do
    sign_in_as(@admin)
    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { name: "", api_key: REPLACEMENT_API_KEY } }
    assert_response :unprocessable_entity
    assert_equal [ "Name can't be blank", "The new API key was not saved; enter it again after correcting the other fields." ], error_messages
    assert_not_includes response.body, REPLACEMENT_API_KEY
    assert_equal [ "Home qBittorrent", API_KEY ], [ @qbit.reload.name, @qbit.api_key ]

    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { client_type: "ftp" } }
    assert_response :unprocessable_entity
    assert_equal "qbittorrent", @qbit.reload.client_type
  end

  test "a change made from an out-of-date copy is refused with the current listing and nothing is written" do
    sign_in_as(@admin)
    stale = version(@qbit)
    stale_rule = version(@rule)
    travel 1.second do
      @qbit.update!(category: "someone-else")
      @rule.update!(enabled: false)
    end

    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: stale, client: { name: "Mine" } }
    assert_response :conflict
    assert_equal "download_changed", response.parsed_body.fetch("error")
    assert_equal "someone-else", client_json(response.parsed_body, @qbit).fetch("category")
    assert_equal "Home qBittorrent", @qbit.reload.name

    write :delete, web_preview_api_admin_download_client_path(id: @qbit.id), { version: stale, rules: [] }
    assert_response :conflict
    assert DownloadClient.exists?(@qbit.id)

    write :put, web_preview_api_admin_download_rule_path(id: @rule.id), { version: stale_rule, rule: { indexer_name: "Mine" } }
    assert_response :conflict
    write :delete, web_preview_api_admin_download_rule_path(id: @rule.id), { version: stale_rule }
    assert_response :conflict
    assert_equal "MyAnonaMouse", @rule.reload.indexer_name

    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { client: { name: "Mine" } }
    assert_response :bad_request
    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: [ stale ], client: { name: "Mine" } }
    assert_response :bad_request
    assert_equal "Home qBittorrent", @qbit.reload.name
  end

  test "two administrators saving the same client: the second is told and the first change stays" do
    sign_in_as(@admin)
    opened = version(@qbit)
    travel 1.second do
      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: opened, client: { category: "first" } }
      assert_response :success
    end
    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: opened, client: { category: "second" } }
    assert_response :conflict
    assert_equal "first", @qbit.reload.category
  end

  test "removing a client removes its routing rules and says so" do
    sign_in_as(@admin)
    write :delete, web_preview_api_admin_download_client_path(id: @second.id), { version: version(@second), rules: [ @rule.id.to_s ] }
    assert_response :success
    assert_equal "Download client “Seedbox qBittorrent” removed with its routing rule.", response.parsed_body.dig("outcome", "message")
    assert_not DownloadClient.exists?(@second.id)
    assert_not DownloadRoutingRule.exists?(@rule.id)
    assert_empty response.parsed_body.fetch("rules")

    write :delete, web_preview_api_admin_download_client_path(id: @second.id), { version: "x", rules: [] }
    assert_response :not_found
    write :delete, web_preview_api_admin_download_client_path(id: "0x1"), { version: "x", rules: [] }
    assert_response :not_found
  end

  test "removing the last enabled client clears the monitor schedule like the classic delete" do
    sign_in_as(@admin)
    Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, Time.current)
    [ @qbit, @second, @sab ].each do |client|
      write :delete, web_preview_api_admin_download_client_path(id: client.id), { version: version(client), rules: client.download_routing_rules.pluck(:id).map(&:to_s) }
      assert_response :success
    end
    assert_nil Rails.cache.read(DownloadMonitorJob::SCHEDULE_CACHE_KEY)
    assert_equal "not_configured", SystemHealth.for_service("download_client").status
  end

  test "test answers with the classic wording, updates health and never shows a client secret" do
    sign_in_as(@admin)
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbit.test:8080")
      stub_qbittorrent_connection("http://seedbox.test:8080")
      stub_request(:get, %r{\Ahttp://sab\.test:8085/api}).to_return(status: 200, body: { categories: [ "*" ] }.to_json, headers: { "Content-Type" => "application/json" })
      write :post, web_preview_api_admin_download_client_test_path(id: @qbit.id)
      assert_response :success
      assert_equal({ "tone" => "success", "message" => "Connection to 'Home qBittorrent' successful!" }, response.parsed_body.fetch("outcome"))
      assert_equal @qbit.id.to_s, response.parsed_body.fetch("tested")
      assert_equal "healthy", response.parsed_body.dig("health", "status")

      WebMock.reset!
      stub_request(:any, /qbit\.test/).to_raise(Errno::ECONNREFUSED.new("Connection refused #{PASSWORD}"))
      stub_qbittorrent_connection("http://seedbox.test:8080")
      stub_request(:get, %r{\Ahttp://sab\.test:8085/api}).to_return(status: 200, body: { categories: [ "*" ] }.to_json, headers: { "Content-Type" => "application/json" })
      write :post, web_preview_api_admin_download_client_test_path(id: @qbit.id)
      assert_equal "error", response.parsed_body.dig("outcome", "tone")
      assert_equal "Connection to 'Home qBittorrent' failed: Connection refused", response.parsed_body.dig("outcome", "message")
      assert_not_includes response.body, PASSWORD
      assert_equal "degraded", response.parsed_body.dig("health", "status")
    end
  end

  test "move swaps within the same client type, ignores the ends and refuses other directions, like the classic arrows" do
    sign_in_as(@admin)
    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, "up"), direction: "up" }
    assert_response :success
    assert_equal [ 1, 0 ], [ @qbit.reload.priority, @second.reload.priority ]
    assert_equal [ "Seedbox qBittorrent", "Home qBittorrent", "SABnzbd" ], response.parsed_body.fetch("clients").map { |client| client.fetch("name") }

    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, "up"), direction: "up" }
    assert_response :conflict
    assert_equal [ 1, 0 ], [ @qbit.reload.priority, @second.reload.priority ]
    write :post, web_preview_api_admin_download_client_move_path(id: @sab.id), { version: version(@sab), neighbour: neighbour(@sab, "down"), direction: "down" }
    assert_response :conflict
    assert_equal 0, @sab.reload.priority
    third = DownloadClient.create!(name: "Third qBittorrent", client_type: "qbittorrent", url: "http://third.test:8080", username: "admin", priority: 2)
    @qbit.update!(client_type: "deluge")
    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: @qbit.id.to_s, direction: "down" }
    assert_response :conflict
    assert_equal [ 0, 2 ], [ @second.reload.priority, third.reload.priority ]

    write :post, web_preview_api_admin_download_client_move_path(id: @qbit.id), { version: version(@qbit), neighbour: neighbour(@qbit, "sideways"), direction: "sideways" }
    assert_response :bad_request
    assert_equal [ 1, 0 ], [ @qbit.reload.priority, @second.reload.priority ]
  end

  test "routing rules: add, change and remove with the classic validation, and the rule routes matching results" do
    sign_in_as(@admin)
    write :post, web_preview_api_admin_download_rules_path, { rule: { provider: "jackett", indexer_name: "  Books   Galore ", download_type: "torrent", download_client_id: @qbit.id.to_s, enabled: true } }
    assert_response :created
    rule = DownloadRoutingRule.find(response.parsed_body.fetch("created"))
    assert_equal [ "jackett", "Books Galore", "books galore" ], [ rule.provider, rule.indexer_name, rule.normalized_indexer_name ]
    assert_equal @qbit, DownloadRoutingRule.routed_client_for(Result.new(source: SearchResult::SOURCE_JACKETT, indexer: "BOOKS galore", download_type: "torrent"))
    assert_nil DownloadRoutingRule.routed_client_for(Result.new(source: SearchResult::SOURCE_PROWLARR, indexer: "Books Galore", download_type: "torrent"))

    [
      { provider: "jackett", indexer_name: "books galore", download_type: "torrent", download_client_id: @second.id.to_s },
      { provider: "jackett", indexer_name: "Usenet please", download_type: "usenet", download_client_id: @qbit.id.to_s },
      { provider: "tracker", indexer_name: "", download_type: "direct", download_client_id: "" },
      { provider: "prowlarr", indexer_name: "No client", download_type: "torrent", download_client_id: "abc" }
    ].each do |attributes|
      classic = assert_no_difference -> { DownloadRoutingRule.count } do
        post admin_download_routing_rules_url, params: { download_routing_rule: attributes }
        assert_response :unprocessable_entity
        css_select("ul.list-disc li").map { |item| item.text.strip }
      end
      assert_no_difference -> { DownloadRoutingRule.count } do
        write :post, web_preview_api_admin_download_rules_path, { rule: attributes }
      end
      assert_response :unprocessable_entity
      assert_equal classic, error_messages, attributes.inspect
    end

    write :put, web_preview_api_admin_download_rule_path(id: rule.id), { version: version(rule), rule: { download_type: "usenet", download_client_id: @sab.id.to_s } }
    assert_response :success
    assert_equal @sab, DownloadRoutingRule.routed_client_for(Result.new(source: SearchResult::SOURCE_JACKETT, indexer: "books galore", download_type: "usenet"))

    @sab.update!(enabled: false)
    body = downloads_json
    assert_equal [ false, true ], body.fetch("rules").find { |entry| entry.fetch("id") == rule.id.to_s }.values_at("client_enabled", "enabled")
    assert_nil DownloadRoutingRule.routed_client_for(Result.new(source: SearchResult::SOURCE_JACKETT, indexer: "books galore", download_type: "usenet"))

    write :put, web_preview_api_admin_download_rule_path(id: rule.id), { version: version(rule), rule: { enabled: false } }
    assert_not rule.reload.enabled?
    write :delete, web_preview_api_admin_download_rule_path(id: rule.id), { version: version(rule) }
    assert_response :success
    assert_equal "Routing rule for “Books Galore” removed.", response.parsed_body.dig("outcome", "message")
    assert_not DownloadRoutingRule.exists?(rule.id)
  end

  test "the overview links download client health to the clients card and no longer lists download screens as missing" do
    SystemHealth.for_service("download_client").check_failed!(message: "All clients failed: Home qBittorrent")
    sign_in_as(@admin)
    preview_get web_preview_api_admin_overview_path, user: @admin
    service = response.parsed_body.fetch("services").find { |entry| entry.fetch("service") == "download_client" }
    assert_equal({ "category" => "downloads", "group" => "download_clients", "label" => "Download clients" }, service.fetch("fix"))
    labels = response.parsed_body.fetch("pending").map { |entry| entry.fetch("label") }
    assert_empty labels & [ "Download clients", "Download routing" ]
    assert_equal [ "Audible backup" ], labels
  end

  test "the classic download screens and their writes keep working" do
    sign_in_as(@admin)
    get admin_download_clients_url
    assert_response :success
    get admin_download_routing_rules_url
    assert_response :success
    post move_down_admin_download_client_url(@qbit)
    assert_equal [ 1, 0 ], [ @qbit.reload.priority, @second.reload.priority ]
    get web_preview_server_category_path(category: "downloads")
    assert_response :success
  end

  test "an address shows only its scheme, host, port and path, and its sign-in and query never appear in any answer" do
    sign_in_as(@admin)
    @sab.update!(url: "http://reader:url-secret-5150@sab.test:8085/sabnzbd?apikey=query-secret-7788")
    body = downloads_json
    [ "url-secret-5150", "query-secret-7788" ].each { |secret| assert_not_includes response.body, secret }
    assert_equal [ "http://sab.test:8085/sabnzbd", true ], client_json(body, @sab).values_at("url", "url_hidden")

    VCR.turned_off do
      stub_request(:any, /sab\.test/).to_raise(StandardError.new("bad response from http://reader:url-secret-5150@sab.test:8085 key query-secret-7788"))
      stub_request(:any, /qbit\.test|seedbox\.test/).to_raise(Errno::ECONNREFUSED)
      write :post, web_preview_api_admin_download_client_test_path(id: @sab.id)
      [ "url-secret-5150", "query-secret-7788" ].each { |secret| assert_not_includes response.body, secret }
      assert_equal "Connection to 'SABnzbd' failed: #{DownloadClientAdministration::UNCLASSIFIED_FAILURE}", response.parsed_body.dig("outcome", "message")

      write :put, web_preview_api_admin_download_client_path(id: @sab.id), { version: version(@sab), client: { category: "books" } }
    end
    assert_response :success
    assert_equal "http://reader:url-secret-5150@sab.test:8085/sabnzbd?apikey=query-secret-7788", @sab.reload.url
  end

  test "Test and health never echo what a client or library said, so no saved or short secret can appear" do
    sign_in_as(@admin)
    @second.update!(password: "abc")
    SystemHealth.for_service("download_client").check_failed!(message: "Seedbox qBittorrent (rejected abc and #{PASSWORD})", degraded: true)
    VCR.turned_off do
      stub_request(:any, /seedbox\.test/).to_raise(StandardError.new("rejected abc for admin with #{PASSWORD}"))
      stub_request(:any, /qbit\.test|sab\.test/).to_raise(Errno::ECONNREFUSED)
      write :post, web_preview_api_admin_download_client_test_path(id: @second.id)
    end
    assert_equal "Connection to 'Seedbox qBittorrent' failed: #{DownloadClientAdministration::UNCLASSIFIED_FAILURE}", response.parsed_body.dig("outcome", "message")
    [ "abc", PASSWORD ].each { |secret| assert_not_includes response.body, secret }

    preview_get web_preview_api_admin_overview_path, user: @admin
    service = response.parsed_body.fetch("services").find { |entry| entry.fetch("service") == "download_client" }
    assert_equal "No enabled client answered the last check. Test each client to see why.", service.fetch("message")
    assert_includes SystemHealth.for_service("download_client").message, PASSWORD
    assert_not_includes response.body, PASSWORD
  end

  test "moving keeps the classic swap of saved priorities, and a tie is reported instead of renumbering anything" do
    sign_in_as(@admin)
    @qbit.update_columns(priority: 3)
    @second.update_columns(priority: 7)
    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, "up"), direction: "up" }
    assert_equal [ 7, 3 ], [ @qbit.reload.priority, @second.reload.priority ]
    assert_equal true, response.parsed_body.fetch("moved")

    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, "up"), direction: "up" }
    assert_response :conflict

    @second.update_columns(priority: 7)
    answers = %w[up down].map do |direction|
      write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: version(@second), neighbour: neighbour(@second, direction), direction: direction }
      response.parsed_body.dig("outcome", "message").to_s
    end
    assert answers.any? { |message| message.include?("has the same priority as the client") }, answers.inspect
    assert_equal [ 7, 7 ], [ @qbit.reload.priority, @second.reload.priority ]
  end

  test "a whole number too large to store is refused as a field error, and the address never reaches the request log" do
    sign_in_as(@admin)
    write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { torrent_verification_wait_time: "9223372036854775808" } }
    assert_response :unprocessable_entity
    assert_equal [ { "field" => "torrent_verification_wait_time", "message" => "Torrent verification wait time must be 9007199254740991 or less" } ], response.parsed_body.fetch("errors")
    assert_equal 2, @qbit.reload.torrent_verification_wait_time

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("client" => { "url" => "http://reader:secret@sab.test", "name" => "SABnzbd" })
    assert_equal({ "client" => { "url" => "[FILTERED]", "name" => "SABnzbd" } }, filtered)
  end

  test "changing a client's type keeps its saved priority like the classic form, and its rules say they no longer match" do
    sign_in_as(@admin)
    write :put, web_preview_api_admin_download_client_path(id: @second.id), { version: version(@second), client: { client_type: "sabnzbd" } }
    assert_response :success
    assert_equal 1, @second.reload.priority
    rule = response.parsed_body.fetch("rules").sole
    assert_equal [ "usenet", "torrent" ], rule.values_at("client_kind", "download_type")
  end

  test "removing a client is refused when its routing rules are not exactly the ones confirmed" do
    sign_in_as(@admin)
    write :delete, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), rules: [] }
    assert_response :success
    confirmed = [ @rule.id.to_s ]
    @rule.destroy!
    replacement = DownloadRoutingRule.create!(provider: "jackett", indexer_name: "Late", download_type: "torrent", download_client: @second)
    write :delete, web_preview_api_admin_download_client_path(id: @second.id), { version: version(@second), rules: confirmed }
    assert_response :conflict
    assert DownloadRoutingRule.exists?(replacement.id)
    write :delete, web_preview_api_admin_download_client_path(id: @second.id), { version: version(@second), rules: 1 }
    assert_response :bad_request
    write :delete, web_preview_api_admin_download_client_path(id: @second.id), { version: version(@second) }
    assert_response :bad_request
    assert DownloadClient.exists?(@second.id)
  end

  test "a switch sent as null, blank or anything but on or off is refused before it reaches the database" do
    sign_in_as(@admin)
    [ nil, "", "maybe" ].each do |value|
      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { enabled: value } }
      assert_response :bad_request, value.inspect
      write :put, web_preview_api_admin_download_rule_path(id: @rule.id), { version: version(@rule), rule: { enabled: value } }
      assert_response :bad_request, value.inspect
    end
    assert @qbit.reload.enabled?
    assert @rule.reload.enabled?
  end

  test "moves carry the version and the neighbour the page showed" do
    sign_in_as(@admin)
    write :post, web_preview_api_admin_download_client_move_path(id: @second.id), { version: "stale", neighbour: @qbit.id.to_s, direction: "up" }
    assert_response :conflict
    assert_equal [ 0, 1 ], [ @qbit.reload.priority, @second.reload.priority ]
  end

  test "Test always uses the saved settings; values sent with it are ignored and never reach a downloader" do
    sign_in_as(@admin)
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbit.test:8080")
      stub_request(:any, /seedbox\.test|sab\.test/).to_raise(Errno::ECONNREFUSED)
      write :post, web_preview_api_admin_download_client_test_path(id: @qbit.id), { version: "old", draft: true, client: { url: "http://elsewhere.test:8080", password: "typed-pw-5" } }
      assert_response :success
      assert_equal "Connection to 'Home qBittorrent' successful!", response.parsed_body.dig("outcome", "message")
      assert_not_requested(:any, /elsewhere\.test/)
      assert_requested(:post, %r{qbit\.test:8080/api/v2/auth/login}, body: hash_including("password" => PASSWORD)) if @qbit.reload.api_key.nil?
    end
    assert_equal "http://qbit.test:8080", @qbit.reload.url
  end

  test "a whole number within the database's range is stored like the classic form" do
    sign_in_as(@admin)
    VCR.turned_off do
      stub_request(:any, /qbit\.test|seedbox\.test|sab\.test/).to_raise(Errno::ECONNREFUSED)
      write :put, web_preview_api_admin_download_client_path(id: @qbit.id), { version: version(@qbit), client: { torrent_verification_wait_time: "2147483648" } }
    end
    assert_response :success
    assert_equal 2_147_483_648, @qbit.reload.torrent_verification_wait_time
  end

end
