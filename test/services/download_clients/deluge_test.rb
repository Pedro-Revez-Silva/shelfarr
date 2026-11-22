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
    stub_deluge_rpc("core.get_config_value", false, params: [ "add_paused" ])
    stub_deluge_rpc("core.set_torrent_options", nil)
    stub_deluge_rpc("core.resume_torrent", nil)
  end

  test "add_torrent adds magnet and returns id" do
    VCR.turned_off do
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

  test "add_torrent stages a paused torrent, keeps it after its share ratio, then resumes it" do
    VCR.turned_off do
      stub_deluge_login
      captured = nil
      stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          next false unless body["method"] == "core.add_torrent_magnet"

          captured = body.dig("params", 1)
          true
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "new_torrent_id", error: nil, id: 1 }.to_json
        )
      options_stub = stub_deluge_rpc(
        "core.set_torrent_options",
        nil,
        params: [ [ "new_torrent_id" ], { "remove_at_ratio" => false } ]
      )
      resume_stub = stub_deluge_rpc("core.resume_torrent", nil, params: [ [ "new_torrent_id" ] ])

      methods = recorded_deluge_methods do
        assert_equal "new_torrent_id", @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_equal({ "add_paused" => true, "remove_at_ratio" => false }, captured)
      assert_requested options_stub, times: 1
      assert_requested resume_stub, times: 1
      assert_equal(
        [ "core.get_config_value", "core.add_torrent_magnet", "core.set_torrent_options", "core.resume_torrent" ],
        methods - [ "auth.login" ]
      )
    end
  end

  test "add_torrent leaves the torrent paused when Deluge adds new torrents paused" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.get_config_value", true, params: [ "add_paused" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      options_stub = stub_deluge_rpc(
        "core.set_torrent_options",
        nil,
        params: [ [ "new_torrent_id" ], { "remove_at_ratio" => false } ]
      )

      assert_equal "new_torrent_id", @client.add_torrent("magnet:?xt=urn:btih:abcdef")

      assert_requested options_stub, times: 1
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.resume_torrent"/
    end
  end

  test "add_torrent follows an explicit paused option instead of the Deluge default" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.get_config_value", true, params: [ "add_paused" ])
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      resume_stub = stub_deluge_rpc("core.resume_torrent", nil, params: [ [ "new_torrent_id" ] ])

      assert_equal "new_torrent_id", @client.add_torrent("magnet:?xt=urn:btih:abcdef", paused: false)
      assert_requested resume_stub, times: 1

      assert_equal "new_torrent_id", @client.add_torrent("magnet:?xt=urn:btih:abcdef", paused: true)
      assert_requested resume_stub, times: 1
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.get_config_value"/
    end
  end

  test "add_torrent removes only the staged torrent metadata when the ratio override fails" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      stub_deluge_rpc("core.set_torrent_options", nil, error: { "message" => "Unknown torrent" })
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], false ])

      error = assert_raises(DownloadClients::Base::ConfigurationError) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_match(/core.set_torrent_options/, error.message)
      assert_requested remove_stub, times: 1
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.resume_torrent"/
    end
  end

  test "add_torrent removes only the staged torrent metadata when resume loses the connection" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.resume_torrent"/)
        .to_raise(Faraday::ConnectionFailed.new("connection lost"))
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], false ])

      assert_raises(DownloadClients::Base::ConfigurationError) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_requested remove_stub, times: 1
    end
  end

  test "add_torrent leaves a staged torrent it cannot remove paused instead of removing it later by hash" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      stub_deluge_rpc("core.set_torrent_options", nil, error: { "message" => "Unknown torrent" })
      remove_stub = stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.remove_torrents"/)
        .to_raise(Faraday::ConnectionFailed.new("connection lost"))

      assert_no_enqueued_jobs only: StaleClientDispatchCleanupJob do
        assert_raises(DownloadClients::Base::ConfigurationError) do
          @client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
      end
      assert_requested remove_stub, times: 1
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.resume_torrent"/
    end
  end

  test "add_torrent reports a lost add response as needing a check in Deluge and makes no further calls" do
    VCR.turned_off do
      torrent_hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      stub_deluge_login
      [
        Faraday::TimeoutError.new("timed out"),
        Faraday::ConnectionFailed.new(Errno::ECONNRESET.new),
        Faraday::ConnectionFailed.new("end of file reached")
      ].each do |lost|
        stub_request(:post, "http://localhost:8112/json")
          .with(body: /"core.add_torrent_magnet"/)
          .to_raise(lost)

        error = assert_raises(DownloadClients::Base::ConfigurationError) do
          @client.add_torrent("magnet:?xt=urn:btih:#{torrent_hash}")
        end
        assert_match(/did not confirm whether it added/, error.message)
        assert_match(/whether another request or tool uses it; if nothing does, remove it in Deluge, then retry/, error.message)
      end

      assert_not_requested :post, "http://localhost:8112/json", body: /"core.get_torrents_status"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.set_torrent_options"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.resume_torrent"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.remove_torrents"/
    end
  end

  test "add_torrent keeps an add that never reached Deluge as a connection error" do
    VCR.turned_off do
      stub_deluge_login
      [
        Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new),
        Faraday::TimeoutError.new(Net::OpenTimeout.new)
      ].each do |undelivered|
        stub_request(:post, "http://localhost:8112/json")
          .with(body: /"core.add_torrent_magnet"/)
          .to_raise(undelivered)

        error = assert_raises(DownloadClients::Base::ConnectionError) do
          @client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
        assert_instance_of DownloadClients::Base::ConnectionError, error
      end

      assert_not_requested :post, "http://localhost:8112/json", body: /"core.remove_torrents"/
    end
  end

  test "add_torrent reports an authentication failure while staging as a client configuration failure" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.add_torrent_magnet", "new_torrent_id")
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.set_torrent_options"/)
        .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: {}.to_json)
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], false ])

      assert_raises(DownloadClients::Base::ConfigurationError) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_requested remove_stub, times: 1
    end
  end

  test "add_torrent reports an unreadable add_paused setting as a client configuration failure" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.get_config_value", nil, params: [ "add_paused" ], error: { "message" => "Unknown method" })

      assert_raises(DownloadClients::Base::ConfigurationError) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end

      assert_not_requested :post, "http://localhost:8112/json", body: /"core.add_torrent_magnet"/
    end
  end

  test "add_torrent neither adopts nor removes a torrent that is already in Deluge" do
    VCR.turned_off do
      existing_hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      stub_deluge_login
      stub_deluge_rpc(
        "core.add_torrent_magnet",
        nil,
        error: { "message" => "Torrent already in session (#{existing_hash})." }
      )

      error = assert_raises(DownloadClients::Base::ConfigurationError) do
        @client.add_torrent("magnet:?xt=urn:btih:#{existing_hash}")
      end

      assert_match(/already in session/, error.message)
      assert_match(/did not adopt or change it/, error.message)
      assert_match(/whether another request or tool uses it/, error.message)
      assert_match(/may have merged this release's trackers/, error.message)
      assert_match(/remove it in Deluge, then retry/, error.message)
      assert_no_match(/untouched/, error.message)
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.set_torrent_options"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.resume_torrent"/
      assert_not_requested :post, "http://localhost:8112/json", body: /"core.remove_torrents"/
      assert_no_enqueued_jobs only: StaleClientDispatchCleanupJob
    end
  end

  test "add_torrent disables remove_at_ratio again after a label applies queue settings" do
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

      captured = nil
      stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          next false unless body["method"] == "core.add_torrent_magnet"

          captured = body.dig("params", 1)
          true
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: "new_torrent_id", error: nil, id: 1 }.to_json
        )

      stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "label.set_torrent" && body["params"] == [ "new_torrent_id", "shelfarr" ]
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: nil, error: nil, id: 1 }.to_json
        )

      options_stub = stub_request(:post, "http://localhost:8112/json")
        .with do |request|
          body = JSON.parse(request.body)
          body["method"] == "core.set_torrent_options" &&
            body["params"] == [ [ "new_torrent_id" ], { "remove_at_ratio" => false } ]
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: nil, error: nil, id: 1 }.to_json
        )

      methods = recorded_deluge_methods do
        assert_equal "new_torrent_id", client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end
      assert_equal true, captured["add_paused"]
      assert_equal false, captured["remove_at_ratio"]
      assert_requested options_stub, times: 1

      assert_equal(
        [ "core.add_torrent_magnet", "label.set_torrent", "core.set_torrent_options", "core.resume_torrent" ],
        methods & [ "core.add_torrent_magnet", "label.set_torrent", "core.set_torrent_options", "core.resume_torrent" ]
      )
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
      stub_deluge_rpc("core.set_torrent_options", nil)

      assert_equal "new_torrent_id", client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_requested(add_stub)
      assert_requested(label_stub)
    end
  end

  test "add_torrent retries transient label failures before removing the staged torrent metadata" do
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
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], false ])

      client.stub(:sleep, nil) do
        assert_raises DownloadClients::Base::Error do
          client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
      end

      assert_requested(set_stub, times: DownloadClients::Deluge::LABEL_ASSIGN_MAX_ATTEMPTS)
      assert_requested(remove_stub)
    end
  end

  test "add_torrent leaves the staged torrent paused when Deluge reports a removal error" do
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
        params: [ [ "new_torrent_id" ], false ]
      )

      assert_no_enqueued_jobs only: StaleClientDispatchCleanupJob do
        assert_raises DownloadClients::Base::ConfigurationError do
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
      remove_stub = stub_deluge_rpc("core.remove_torrents", [], params: [ [ "new_torrent_id" ], false ])

      client.stub(:sleep, nil) do
        assert_raises DownloadClients::Base::ConfigurationError do
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
      stub_deluge_rpc("core.set_torrent_options", nil)

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
      stub_deluge_rpc("core.set_torrent_options", nil)

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
              "existing_torrent" => {
                "name" => "Test Torrent",
                "progress" => 50.0,
                "state" => "Downloading",
                "total_size" => 1073741824,
                "save_path" => "/downloads/Test Torrent"
              }
            },
            error: nil,
            id: 1
          }.to_json
        )

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

      assert RemoteResult.failed?(client.test_connection)
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
                "progress" => 100.0,
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

  test "torrent_info returns nil only when Deluge answers that the torrent is missing" do
    VCR.turned_off do
      stub_deluge_login
      stub_deluge_rpc("core.get_torrents_status", {})

      assert_nil @client.torrent_info("missing_torrent")
      assert_equal [], @client.list_torrents
    end
  end

  test "torrent_info raises for a status reply that is not a torrent map" do
    VCR.turned_off do
      stub_deluge_login
      [ nil, false, [] ].each do |result|
        stub_deluge_rpc("core.get_torrents_status", result)

        assert_raises(DownloadClients::Base::ConnectionError, "result #{result.inspect}") { @client.torrent_info("known_torrent") }
        assert_raises(DownloadClients::Base::ConnectionError, "result #{result.inspect}") { @client.list_torrents }
      end
    end
  end

  test "an expired Deluge Web session is dropped so the next read logs in again" do
    VCR.turned_off do
      Thread.current[:deluge_sessions] = { @client_record.id => { cookie: "sessionid=cached" } }
      login = stub_deluge_login
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.get_torrents_status"/)
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: { result: nil, error: { "message" => "Not authenticated", "code" => 1 }, id: 1 }.to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: { result: {}, error: nil, id: 1 }.to_json }
        )

      assert_raises(DownloadClients::Base::AuthenticationError) { @client.torrent_info("known_torrent") }
      assert_nil @client.torrent_info("known_torrent")
      assert_requested login, times: 1
    end
  end

  test "torrent_info and list_torrents raise when a cached Deluge session cannot read torrents" do
    VCR.turned_off do
      Thread.current[:deluge_sessions] = { @client_record.id => { cookie: "sessionid=cached" } }
      responses = {
        DownloadClients::Base::ConnectionError => { status: 503, body: {}.to_json },
        DownloadClients::Base::AuthenticationError => { status: 200, body: { result: nil, error: { "message" => "Not logged in" }, id: 1 }.to_json },
        DownloadClients::Base::Error => { status: 200, body: { result: nil, error: { "message" => "Unknown method" }, id: 1 }.to_json }
      }

      responses.each do |error_class, response|
        Thread.current[:deluge_sessions] = { @client_record.id => { cookie: "sessionid=cached" } }
        stub_request(:post, "http://localhost:8112/json")
          .with(body: /"core.get_torrents_status"/)
          .to_return(response.merge(headers: { "Content-Type" => "application/json" }))

        assert_raises(error_class) { @client.torrent_info("known_torrent") }
        Thread.current[:deluge_sessions] = { @client_record.id => { cookie: "sessionid=cached" } }
        assert_raises(error_class) { @client.list_torrents }
      end
    end
  end

  test "torrent_info treats finished paused and stopped torrents as completed" do
    VCR.turned_off do
      stub_deluge_login

      {
        "seeding-hash" => [ "Seeding", 100 ],
        "paused-hash" => [ "Paused", 100 ],
        "stopped-hash" => [ "Stopped", 100 ],
        "paused-download-hash" => [ "PausedDownload", 100 ],
        "paused-upload-hash" => [ "PausedUpload", 100 ]
      }.each do |torrent_id, (state, progress)|
        stub_deluge_torrent_status(torrent_id, state: state, progress: progress)

        info = @client.torrent_info(torrent_id)

        assert_not_nil info, "#{state} at #{progress}% should return torrent info"
        assert info.completed?, "#{state} at #{progress}% should be completed, got #{info.state}"
        assert_equal :completed, info.state
        assert_equal 100, info.progress
      end
    end
  end

  test "torrent_info does not treat incomplete paused or error torrents as completed" do
    VCR.turned_off do
      stub_deluge_login

      {
        "paused-partial-hash" => [ "Paused", 50, :paused ],
        "stopped-partial-hash" => [ "Stopped", 42, :paused ],
        "error-hash" => [ "Error", 100, :failed ],
        "error-pause-hash" => [ "ErrorPause", 100, :failed ]
      }.each do |torrent_id, (state, progress, expected_state)|
        stub_deluge_torrent_status(torrent_id, state: state, progress: progress)

        info = @client.torrent_info(torrent_id)

        assert_not_nil info, "#{state} at #{progress}% should return torrent info"
        assert_not info.completed?, "#{state} at #{progress}% should not be completed"
        assert_equal expected_state, info.state
      end
    end
  end

  test "torrent download path appends a name matching the download root basename" do
    data = { "download_location" => "/downloads/shelfarr", "name" => "shelfarr" }

    assert_equal "/downloads/shelfarr/shelfarr", @client.send(:torrent_download_path, data)
  end

  test "torrent_info keeps incomplete paused percentages below completion even when display rounds up" do
    VCR.turned_off do
      stub_deluge_login

      %w[Paused PausedDownload PausedUpload Stopped].each do |state|
        [ 0.5, 1.0, 99.49, 99.5, 99.99 ].each do |progress|
          stub_deluge_torrent_status("partial", state: state, progress: progress)

          info = @client.torrent_info("partial")

          assert_equal :paused, info.state, "#{state} at #{progress}% must remain paused"
          assert_equal progress.round, info.progress
          assert_not info.completed?
        end
      end
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
          body: { result: [], error: nil, id: 1 }.to_json
        )

      assert @client.remove_torrent("known_torrent")
    end
  end

  test "add_torrent reports an add whose reply cannot be read as needing a check in Deluge" do
    VCR.turned_off do
      stub_deluge_login
      [
        { status: 200, body: "not a hash".to_json },
        { status: 200, body: { result: nil, error: nil, id: 1 }.to_json },
        { status: 204, body: "" },
        { status: 408, body: { error: "unavailable" }.to_json },
        { status: 429, body: { error: "unavailable" }.to_json },
        { status: 503, body: { error: "unavailable" }.to_json },
        { status: 500, body: {}.to_json },
        { status: 502, body: {}.to_json },
        { status: 504, body: {}.to_json }
      ].each do |reply|
        stub_request(:post, "http://localhost:8112/json")
          .with(body: /"core.add_torrent_magnet"/)
          .to_return(reply.merge(headers: { "Content-Type" => "application/json" }))

        error = assert_raises(DownloadClients::Base::ConfigurationError, "reply #{reply}") do
          @client.add_torrent("magnet:?xt=urn:btih:abcdef")
        end
        assert_match(/did not confirm whether it added/, error.message)
      end

      assert_not_requested :post, "http://localhost:8112/json", body: /"core.(set_torrent_options|resume_torrent|remove_torrents)"/
    end
  end

  test "add_torrent keeps a 400 API status as Error" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"core.add_torrent_magnet"/)
        .to_return(
          status: 400,
          headers: { "Content-Type" => "application/json" },
          body: { error: "bad torrent" }.to_json
        )

      error = assert_raises(DownloadClients::Base::Error) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end
      assert_instance_of DownloadClients::Base::Error, error
      assert_equal "Deluge API error: 400", error.message
    end
  end

  test "add_torrent keeps a Deluge error object as Error" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8112/json")
        .with(body: /"auth.login"/)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
          body: { result: true, error: nil, id: 1 }.to_json
        )
      stub_deluge_rpc("core.add_torrent_magnet", nil, error: { "message" => "Invalid torrent" })

      error = assert_raises(DownloadClients::Base::Error) do
        @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      end
      assert_instance_of DownloadClients::Base::Error, error
      assert_match(/Invalid torrent/, error.message)
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

  def recorded_deluge_methods
    recorded = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.size
    yield
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.drop(recorded).map do |signature|
      JSON.parse(signature.body)["method"]
    end
  end

  def stub_deluge_login
    stub_request(:post, "http://localhost:8112/json")
      .with(body: /"auth.login"/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
        body: { result: true, error: nil, id: 1 }.to_json
      )
  end

  def stub_deluge_torrent_status(torrent_id, state:, progress:)
    stub_request(:post, "http://localhost:8112/json")
      .with(body: /"core.get_torrents_status"/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          result: {
            torrent_id => {
              "name" => "Finished Book",
              "progress" => progress,
              "state" => state,
              "total_size" => 2048,
              "download_location" => "/downloads",
              "save_path" => "/legacy-downloads"
            }
          },
          error: nil,
          id: 1
        }.to_json
      )
  end

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
