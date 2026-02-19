# frozen_string_literal: true

require "test_helper"

class DownloadClients::TransmissionTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter

    Thread.current[:transmission_sessions] = {}
  end

  test "add_torrent adds torrent and returns hash" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-get"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => { "torrents" => [ { "hashString" => "existing" } ] } }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-add"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => { "torrent-added" => { "hashString" => "new-torrent-id" } } }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_equal "new-torrent-id", result
    end
  end

  test "add_torrent returns existing torrent id when duplicate" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-get"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => { "torrents" => [ { "hashString" => "existing" } ] } }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-add"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => { "torrent-duplicate" => { "hashString" => "existing" } } }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:existing")
      assert_equal "existing", result
    end
  end

  test "list_torrents returns array of TorrentInfo" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-get"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => "success",
            "arguments" => {
              "torrents" => [
                {
                  "hashString" => "abc123",
                  "name" => "Transmission Book",
                  "percentDone" => 0.5,
                  "status" => 4,
                  "totalSize" => 1073741824,
                  "downloadDir" => "/downloads/Transmission Book"
                }
              ]
            }
          }.to_json
        )

      torrents = @client.list_torrents

      assert_kind_of Array, torrents
      assert_equal 1, torrents.size

      torrent = torrents.first
      assert_kind_of DownloadClients::Base::TorrentInfo, torrent
      assert_equal "abc123", torrent.hash
      assert_equal "Transmission Book", torrent.name
      assert_equal 50, torrent.progress
      assert_equal :downloading, torrent.state
    end
  end

  test "torrent_info returns nil when missing" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-get"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => "success",
            "arguments" => { "torrents" => [] }
          }.to_json
        )

      info = @client.torrent_info("missing")
      assert_nil info
    end
  end

  test "remove_torrent returns true on success" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"torrent-remove"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => {} }.to_json
        )

      assert @client.remove_torrent("abc123", delete_files: true)
    end
  end

  test "test_connection returns false on authentication failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(body: /"method"\s*:\s*"session-get"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "session", "arguments" => {} }.to_json
        )

      assert_not @client.test_connection
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")

      assert @client.test_connection
    end
  end

  test "uses basic authentication header when username and password are set" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(
          body: /"method"\s*:\s*"session-get"/,
          basic_auth: [ "admin", "adminadmin" ]
        )
        .to_return(
          status: 409,
          headers: { "x-transmission-session-id" => "session-id" },
          body: { "result" => "session", "arguments" => {} }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(
          body: /"method"\s*:\s*"session-get"/,
          basic_auth: [ "admin", "adminadmin" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => {} }.to_json
        )

      assert @client.test_connection
    end
  end

  private

  def stub_session_handshake(url)
    stub_request(:post, url)
      .with(body: /"method"\s*:\s*"session-get"/)
      .to_return(
        {
          status: 409,
          headers: { "x-transmission-session-id" => "session-id" },
          body: { "result" => "session", "arguments" => {} }.to_json
        },
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => {} }.to_json
        }
      )
  end
end
