# frozen_string_literal: true

require "test_helper"

class DownloadClientSelectorTest < ActiveSupport::TestCase
  setup do
    Thread.current[:qbittorrent_sessions] = {}
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
