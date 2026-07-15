# frozen_string_literal: true

require "test_helper"

class DownloadClients::DelugeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
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

  test "add_torrent assigns configured category through the Label plugin" do
    VCR.turned_off do
      @client_record.update!(category: "Shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.get_session_state", [ "known_torrent_id" ])

      add_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          options = body.dig("params", 1)
          body["method"] == "core.add_torrent_magnet" && !options.key?("label")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "new_torrent_id", error: nil, id: 1 }.to_json
        )

      label_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "label.set_torrent" && body["params"] == [ "new_torrent_id", "shelfarr" ]
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: nil, error: nil, id: 1 }.to_json
        )

      assert_equal "new_torrent_id", client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_requested(add_stub)
      assert_requested(label_stub)
    end
  end

  test "add_torrent retries transient label failures before removing its partial files" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.get_session_state", [ "known_torrent_id" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      set_stub = stub_deluge_rpc("label.set_torrent", nil, error: { "message" => "Unknown Torrent" })
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], true ])

      client.stub(:sleep, nil) do
        assert_raises DownloadClients::Base::Error do
          client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
      end

      assert_requested(set_stub, times: DownloadClients::Deluge::LABEL_ASSIGN_MAX_ATTEMPTS)
      assert_requested(remove_stub)
    end
  end

  test "add_torrent schedules cleanup when Deluge reports a removal error" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      stub_deluge_rpc("label.set_torrent", nil, error: { "message" => "Permission denied" })
      stub_deluge_rpc(
        "core.remove_torrents",
        [ [ "new_torrent_id", "Permission denied" ] ],
        params: [ [ "new_torrent_id" ], true ]
      )

      assert_enqueued_with(job: StaleClientDispatchCleanupJob, args: [ @client_record.id, "new_torrent_id" ]) do
        assert_raises DownloadClients::Base::Error do
          client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
      end
    end
  end

  test "add_torrent cleans up after repeated label connection failures" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      set_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"label.set_torrent"/)
        .to_raise(Faraday::ConnectionFailed.new("connection lost"))
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], true ])

      client.stub(:sleep, nil) do
        assert_raises DownloadClients::Base::ConnectionError do
          client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
      end

      assert_requested(set_stub, times: DownloadClients::Deluge::LABEL_ASSIGN_MAX_ATTEMPTS)
      assert_requested(remove_stub)
    end
  end

  test "add_torrent recovers when label assignment fails transiently then succeeds" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.get_session_state", [ "known_torrent_id" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")

      set_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "label.set_torrent" && body["params"] == [ "new_torrent_id", "shelfarr" ]
        end
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: nil, error: { "message" => "Unknown Torrent" }, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: nil, error: nil, id: 1 }.to_json
          }
        )

      client.stub(:sleep, nil) do
        assert_equal "new_torrent_id", client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_requested(set_stub, times: 2)
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.remove_torrents"/
    end
  end

  test "add_torrent recreates a label deleted during dispatch" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      plugins_stub = stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      labels_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"label.get_labels"/)
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [ "shelfarr" ], error: nil, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [], error: nil, id: 1 }.to_json
          }
        )
      add_label_stub = stub_deluge_rpc("label.add", nil, params: [ "shelfarr" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")

      set_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "label.set_torrent" && body["params"] == [ "new_torrent_id", "shelfarr" ]
        end
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: nil, error: { "message" => "Unknown Label" }, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: nil, error: nil, id: 1 }.to_json
          }
        )

      assert_equal "new_torrent_id", client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_requested(plugins_stub, times: 2)
      assert_requested(labels_stub, times: 2)
      assert_requested(add_label_stub)
      assert_requested(set_stub, times: 2)
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.remove_torrents"/
    end
  end

  test "add_torrent raises when a label is configured but no torrent id is returned" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      stub_deluge_rpc("label.get_labels", [ "shelfarr" ])
      stub_deluge_rpc("core.get_session_state", [ "known_torrent_id", "foreign_torrent_id" ])
      stub_deluge_rpc("core.add_torrent_magnet", nil)

      error = assert_raises DownloadClients::Base::Error do
        client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end
      assert_match(/did not return a torrent id/i, error.message)
      assert_not_requested :post, "http://localhost:8112/json", body: /"label.set_torrent"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.get_session_state"/
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

  test "test_connection enables Label plugin and creates configured label" do
    VCR.turned_off do
      @client_record.update!(category: "Shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_session_state", [])
      stub_deluge_rpc("core.get_enabled_plugins", [])
      stub_deluge_rpc("core.get_available_plugins", [ "Label" ])
      enable_stub = stub_deluge_rpc("core.enable_plugin", true, params: [ "Label" ])
      stub_deluge_rpc("label.get_labels", [])
      add_label_stub = stub_deluge_rpc("label.add", nil, params: [ "shelfarr" ])

      assert client.test_connection
      assert_requested(enable_stub)
      assert_requested(add_label_stub)
    end
  end

  test "test_connection retries Label RPC until the plugin is ready after enable" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_session_state", [])
      stub_deluge_rpc("core.get_enabled_plugins", [])
      stub_deluge_rpc("core.get_available_plugins", [ "Label" ])
      stub_deluge_rpc("core.enable_plugin", true, params: [ "Label" ])

      labels_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"label.get_labels"/)
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: nil, error: { "message" => "Unknown method" }, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [], error: nil, id: 1 }.to_json
          }
        )
      add_label_stub = stub_deluge_rpc("label.add", nil, params: [ "shelfarr" ])

      client.stub(:sleep, nil) do
        assert client.test_connection
      end

      assert_requested(labels_stub, times: 2)
      assert_requested(add_label_stub)
    end
  end

  test "test_connection revalidates label readiness for every call" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_session_state", [])
      plugins_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_enabled_plugins"/)
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [ "Label" ], error: nil, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [], error: nil, id: 1 }.to_json
          }
        )
      stub_deluge_rpc("core.get_available_plugins", [ "Label" ])
      enable_stub = stub_deluge_rpc("core.enable_plugin", true, params: [ "Label" ])
      labels_stub = stub_deluge_rpc("label.get_labels", [ "shelfarr" ])

      assert client.test_connection
      assert client.test_connection
      assert_requested(plugins_stub, times: 2)
      assert_requested(labels_stub, times: 2)
      assert_requested(enable_stub)
    end
  end

  test "test_connection tolerates a label created concurrently" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_session_state", [])
      stub_deluge_rpc("core.get_enabled_plugins", [ "Label" ])
      labels_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"label.get_labels"/)
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [], error: nil, id: 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: [ "shelfarr" ], error: nil, id: 1 }.to_json
          }
        )
      stub_deluge_rpc("label.add", nil, error: { "message" => "Label already exists" })

      assert client.test_connection
      assert_requested(labels_stub, times: 2)
    end
  end

  test "test_connection fails when configured label plugin is unavailable" do
    VCR.turned_off do
      @client_record.update!(category: "shelfarr")
      client = @client_record.adapter

      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc("core.get_session_state", [])
      stub_deluge_rpc("core.get_enabled_plugins", [])
      stub_deluge_rpc("core.get_available_plugins", [])

      assert_not client.test_connection
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
                "download_location" => "/downloads",
                "save_path" => "/legacy-downloads"
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
      assert_equal "/downloads/Info Torrent", info.download_path
    end
  end

  test "torrent download path appends a name matching the download root basename" do
    data = { "download_location" => "/downloads/shelfarr", "name" => "shelfarr" }

    assert_equal "/downloads/shelfarr/shelfarr", @client.send(:torrent_download_path, data)
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
          body: { result: [], error: nil, id: 1 }.to_json
        )

      assert @client.remove_torrent("known_torrent")
    end
  end

  test "remove_torrent returns false when Deluge reports removal errors" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )

      stub_deluge_rpc(
        "core.remove_torrents",
        [ [ "known_torrent", "Unknown Torrent" ] ],
        params: [ [ "known_torrent" ], false ]
      )

      assert_not @client.remove_torrent("known_torrent")
    end
  end

  private

  def stub_deluge_rpc(method, result, params: nil, error: nil)
    stub_request(:post, "http://localhost:8112/json")
      .with do |request|
        body = JSON.parse(request.body)
        body["method"] == method && (params.nil? || body["params"] == params)
      end
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { result: result, error: error, id: 1 }.to_json
      )
  end
end
