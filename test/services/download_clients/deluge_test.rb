# frozen_string_literal: true

require "test_helper"

class DownloadClients::DelugeTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter

    Thread.current[:deluge_sessions] = {}
  end

  test "add_torrent adds torrent and returns id" do
    VCR.turned_off do
      # Login (auth.login)
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      # session state before add
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_session_state"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: [ "known_torrent_id" ], error: nil, id: 1 }.to_json
        )

      # add_torrent_url returns id directly
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.add_torrent_url"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "new_torrent_id", error: nil, id: 1 }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_equal "new_torrent_id", result
    end
  end

  test "list_torrents returns array of TorrentInfo" do
    VCR.turned_off do
      # Login (auth.login)
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      # session state for test_connection + status call
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_torrents_status"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            result: {
              "existing_torrent" => {
                "name" => "Test Torrent",
                "progress" => 0.5,
                "state" => "Downloading",
                "total_size" => 1073741824,
                "save_path" => "/downloads/Test Torrent"
              }
            },
            error: nil,
            id: 1
          }.to_json
        )

      # test_connection calls get_session_state indirectly
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_session_state"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: [ "existing_torrent" ], error: nil, id: 1 }.to_json
        )

      torrents = @client.list_torrents
      assert_kind_of Array, torrents
      assert_equal 1, torrents.size

      torrent = torrents.first
      assert_kind_of DownloadClients::Base::TorrentInfo, torrent
      assert_equal "existing_torrent", torrent.hash
      assert_equal "Test Torrent", torrent.name
      assert_equal 50, torrent.progress
      assert_equal :downloading, torrent.state
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      # Login (auth.login)
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_session_state"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: [ "existing_torrent" ], error: nil, id: 1 }.to_json
        )

      assert @client.test_connection
    end
  end

  test "torrent_info returns item by hash" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_torrents_status"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            result: {
              "known_torrent" => {
                "name" => "Info Torrent",
                "progress" => 1.0,
                "state" => "Seeding",
                "total_size" => 2048,
                "save_path" => "/downloads/Info Torrent"
              }
            },
            error: nil,
            id: 1
          }.to_json
        )

      info = @client.torrent_info("known_torrent")
      assert_not_nil info
      assert_equal "known_torrent", info.hash
      assert_equal "Info Torrent", info.name
      assert_equal :completed, info.state
    end
  end

  test "remove_torrent returns true on success" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.remove_torrents"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: { "removed" => true }, error: nil, id: 1 }.to_json
        )

      assert @client.remove_torrent("known_torrent")
    end
  end
end
