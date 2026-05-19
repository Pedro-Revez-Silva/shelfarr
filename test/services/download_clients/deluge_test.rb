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

  test "add_torrent adds magnet and returns id" do
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

      # add_torrent_magnet returns id directly
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.add_torrent_magnet"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "new_torrent_id", error: nil, id: 1 }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_equal "new_torrent_id", result
    end
  end

  test "add_torrent submits resolved magnet when torrent URL redirects to magnet" do
    VCR.turned_off do
      magnet_url = "magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

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
          body: { result: [ "known_torrent_id" ], error: nil, id: 1 }.to_json
        )

      stub_request(:get, "http://prowlarr:9696/api/v1/indexer/download/123")
        .to_return(status: 301, headers: { "Location" => magnet_url })

      add_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "core.add_torrent_magnet" && body["params"].first == magnet_url
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "magnet_torrent_id", error: nil, id: 1 }.to_json
        )

      result = @client.add_torrent("http://prowlarr:9696/api/v1/indexer/download/123")

      assert_equal "magnet_torrent_id", result
      assert_requested(add_stub)
    end
  end

  test "add_torrent uploads fetched torrent payload via add_torrent_file" do
    VCR.turned_off do
      torrent_data = {
        "info" => {
          "name" => "Deluge Book.epub",
          "piece length" => 16_384,
          "pieces" => "s" * 20,
          "length" => 512
        }
      }.bencode

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
          body: { result: [ "known_torrent_id" ], error: nil, id: 1 }.to_json
        )

      stub_request(:get, "http://prowlarr:9696/api/v1/indexer/download/456.torrent")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )

      add_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "core.add_torrent_file" &&
            body["params"][0] == "456.torrent" &&
            body["params"][1] == Base64.strict_encode64(torrent_data)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "file_torrent_id", error: nil, id: 1 }.to_json
        )

      result = @client.add_torrent("http://prowlarr:9696/api/v1/indexer/download/456.torrent")

      assert_equal "file_torrent_id", result
      assert_requested(add_stub)
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

  test "test_connection preserves path-based reverse proxy URL" do
    VCR.turned_off do
      [
        [ "https://example.com/user-trailing/deluge/", "https://example.com/user-trailing/deluge/json" ],
        [ "https://example.com/user-noslash/deluge", "https://example.com/user-noslash/deluge/json" ]
      ].each do |base_url, json_url|
        @client_record.update!(url: base_url)
        Thread.current[:deluge_sessions] = {}
        client = @client_record.adapter

        stub_request(:post, json_url)
          .with(body: /"auth.login"/)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
            body: { result: true, error: nil, id: 1 }.to_json
          )

        stub_request(:post, json_url)
          .with(body: /"core.get_session_state"/)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [ "existing_torrent" ], error: nil, id: 1 }.to_json
          )

        assert client.test_connection, "#{base_url} should connect through #{json_url}"
        assert_requested :post, json_url, times: 2
      end
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
