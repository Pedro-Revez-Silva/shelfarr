# frozen_string_literal: true

require "test_helper"

class DownloadClients::QbittorrentTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter

    # Clear session between tests
    Thread.current[:qbittorrent_sessions] = {}
  end

  test "add_torrent authenticates and adds torrent with magnet link" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Use valid hex hash in magnet link
      result = @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
      assert_equal "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", result
    end
  end

  test "add_torrent returns hash from API for torrent URLs" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub torrent info for getting hash after adding
      stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [{ "hash" => "def456abc789" }].to_json
        )

      result = @client.add_torrent("http://example.com/file.torrent")
      assert_equal "def456abc789", result
    end
  end

  test "list_torrents returns array of TorrentInfo" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub list torrents
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "hash" => "abc123def456",
              "name" => "Test Torrent",
              "progress" => 0.75,
              "state" => "downloading",
              "size" => 1073741824,
              "save_path" => "/downloads"
            }
          ].to_json
        )

      torrents = @client.list_torrents

      assert_kind_of Array, torrents
      assert_equal 1, torrents.size

      torrent = torrents.first
      assert_kind_of DownloadClients::Base::TorrentInfo, torrent
      assert_equal "abc123def456", torrent.hash
      assert_equal "Test Torrent", torrent.name
      assert_equal 75, torrent.progress
      assert_equal :downloading, torrent.state
    end
  end

  test "test_connection returns true when successful" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      assert @client.test_connection
    end
  end

  test "test_connection returns false on authentication failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")

      assert_not @client.test_connection
    end
  end

  test "TorrentInfo.completed? returns true for completed state" do
    info = DownloadClients::Base::TorrentInfo.new(
      hash: "abc123", name: "Test", progress: 100,
      state: :completed, size_bytes: 1000, download_path: "/downloads"
    )
    assert info.completed?
  end

  test "TorrentInfo.downloading? returns true for downloading state" do
    info = DownloadClients::Base::TorrentInfo.new(
      hash: "abc123", name: "Test", progress: 50,
      state: :downloading, size_bytes: 1000, download_path: "/downloads"
    )
    assert info.downloading?
  end

  test "TorrentInfo.failed? returns true for failed state" do
    info = DownloadClients::Base::TorrentInfo.new(
      hash: "abc123", name: "Test", progress: 0,
      state: :failed, size_bytes: 1000, download_path: "/downloads"
    )
    assert info.failed?
  end
end
