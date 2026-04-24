# frozen_string_literal: true

require "test_helper"

class DownloadClientSelectorTest < ActiveSupport::TestCase
  RoutedResult = Struct.new(:indexer, :usenet, :source, keyword_init: true) do
    def usenet?
      usenet
    end

    def download_type
      usenet? ? "usenet" : "torrent"
    end

    def from_indexer?
      true
    end

    def from_jackett?
      source == SearchResult::SOURCE_JACKETT
    end
  end

  setup do
    DownloadRoutingRule.delete_all
    DownloadClient.destroy_all
    Thread.current[:qbittorrent_sessions] = {}
    Thread.current[:deluge_sessions] = {}
    Thread.current[:transmission_sessions] = {}
    Thread.current[:transmission_protocols] = {}
  end

  test "selects torrent client for torrent download" do
    qb = DownloadClient.create!(
      name: "qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 0
    )

    VCR.turned_off do
      stub_qbittorrent_connection("http://localhost:8080")

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal qb, selected
    end
  end

  test "selects usenet client for usenet download" do
    sab = DownloadClient.create!(
      name: "SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-key",
      priority: 0
    )

    VCR.turned_off do
      stub_sabnzbd_version

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, true

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal sab, selected
    end
  end

  test "selects highest priority client" do
    low_priority = DownloadClient.create!(
      name: "Low Priority",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 10
    )
    high_priority = DownloadClient.create!(
      name: "High Priority",
      client_type: "qbittorrent",
      url: "http://localhost:9090",
      username: "admin",
      password: "password",
      priority: 0
    )

    VCR.turned_off do
      # Both succeed connection test
      stub_qbittorrent_connection("http://localhost:9090", session_id: "test")
      stub_qbittorrent_connection("http://localhost:8080", session_id: "test")

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal high_priority, selected
    end
  end

  test "falls back to next client when first fails" do
    failing = DownloadClient.create!(
      name: "Failing",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 0
    )
    working = DownloadClient.create!(
      name: "Working",
      client_type: "qbittorrent",
      url: "http://localhost:9090",
      username: "admin",
      password: "password",
      priority: 1
    )

    VCR.turned_off do
      # First client fails
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")
      # Second client succeeds
      stub_qbittorrent_connection("http://localhost:9090", session_id: "test")

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal working, selected
    end
  end

  test "selects highest-priority torrent client across all torrent types" do
    DownloadClient.create!(
      name: "QB",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 10
    )
    deluge = DownloadClient.create!(
      name: "Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "password",
      priority: 0
    )
    DownloadClient.create!(
      name: "Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      password: "password",
      priority: 1
    )

    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"method"\s*:\s*"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=deluge; path=/" },
          body: { "result" => true, "error" => nil, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"method"\s*:\s*"core.get_session_state"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => ["new-id"], "error" => nil, "id" => 1 }.to_json
        )

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal deluge, selected
    end
  end

  test "falls back to transmission when deluge is not usable" do
    deluge = DownloadClient.create!(
      name: "Down Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "password",
      priority: 0
    )
    transmission = DownloadClient.create!(
      name: "Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      username: "admin",
      password: "password",
      priority: 1
    )

    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"method"\s*:\s*"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=deluge; path=/" },
          body: { "result" => false, "error" => { "message" => "Not logged in" }, "id" => 1 }.to_json
        )

      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "session_get" &&
            body["params"] == {} &&
            body["id"] == 1
        end
        .to_return(
          status: 409,
          headers: { "x-transmission-session-id" => "transmission-session-id" },
          body: { "result" => "session", "arguments" => {} }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "session_get" &&
            body["params"] == {} &&
            body["id"] == 1
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "version" => "4.1.1" }, "id" => 1 }.to_json
        )

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false

      selected = DownloadClientSelector.for_download(search_result)
      assert_equal transmission, selected
    end
  end

  test "raises error when no client of correct type exists" do
    # Only create a usenet client
    DownloadClient.create!(
      name: "SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "key",
      priority: 0
    )

    search_result = Minitest::Mock.new
    search_result.expect :usenet?, false
    search_result.expect :usenet?, false  # Called twice (select + download_type)

    error = assert_raises(DownloadClientSelector::NoClientAvailableError) do
      DownloadClientSelector.for_download(search_result)
    end
    assert_includes error.message, "No torrent download client configured"
  end

  test "raises error when all clients fail connection test" do
    DownloadClient.create!(
      name: "Failing",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 0
    )

    VCR.turned_off do
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")

      search_result = Minitest::Mock.new
      search_result.expect :usenet?, false
      search_result.expect :usenet?, false  # Called twice (select + download_type)

      error = assert_raises(DownloadClientSelector::NoClientAvailableError) do
        DownloadClientSelector.for_download(search_result)
      end
      assert_includes error.message, "all failed connection test"
    end
  end

  test "ignores disabled clients" do
    disabled = DownloadClient.create!(
      name: "Disabled",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      priority: 0,
      enabled: false
    )

    search_result = Minitest::Mock.new
    search_result.expect :usenet?, false
    search_result.expect :usenet?, false  # Called twice (select + download_type)

    error = assert_raises(DownloadClientSelector::NoClientAvailableError) do
      DownloadClientSelector.for_download(search_result)
    end
    assert_includes error.message, "No torrent download client configured"
  end

  test "uses matching routing rule before priority order" do
    DownloadClient.create!(
      name: "Priority Client",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 0
    )
    routed = DownloadClient.create!(
      name: "Private Tracker Client",
      client_type: "qbittorrent",
      url: "http://localhost:9090",
      username: "admin",
      password: "password",
      priority: 10
    )
    DownloadRoutingRule.create!(
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: routed
    )

    VCR.turned_off do
      stub_qbittorrent_connection("http://localhost:8080")
      stub_qbittorrent_connection("http://localhost:9090")

      search_result = RoutedResult.new(
        source: SearchResult::SOURCE_PROWLARR,
        indexer: "myanonamouse",
        usenet: false
      )

      assert_equal routed, DownloadClientSelector.for_download(search_result)
    end
  end

  test "falls back to priority when routed client fails without retesting it" do
    routed = DownloadClient.create!(
      name: "Routed Client",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 10
    )
    fallback = DownloadClient.create!(
      name: "Fallback Client",
      client_type: "qbittorrent",
      url: "http://localhost:9090",
      username: "admin",
      password: "password",
      priority: 0
    )
    DownloadRoutingRule.create!(
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: routed
    )

    VCR.turned_off do
      failing_login = stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")
      stub_qbittorrent_connection("http://localhost:9090")

      search_result = RoutedResult.new(
        source: SearchResult::SOURCE_PROWLARR,
        indexer: "MyAnonaMouse",
        usenet: false
      )

      assert_equal fallback, DownloadClientSelector.for_download(search_result)
      assert_requested failing_login, times: 1
    end
  end

  private

  def stub_sabnzbd_version
    stub_request(:get, %r{localhost:8080/api.*mode=version})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "version" => "4.0.0" }.to_json
      )
  end
end
