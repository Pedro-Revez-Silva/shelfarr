# frozen_string_literal: true

require "test_helper"

class DownloadClients::NzbgetTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test NZBGet",
      client_type: "nzbget",
      url: "http://localhost:6789",
      username: "nzbget",
      password: "tegbzn6789",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter
  end

  test "add_torrent adds NZB successfully" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "appendurl"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => 12345 }.to_json
        )

      result = @client.add_torrent("http://example.com/test.nzb")
      assert result
      assert_equal [ "12345" ], result["nzo_ids"]
    end
  end

  test "add_torrent returns false on failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(basic_auth: [ "nzbget", "tegbzn6789" ])
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => 0 }.to_json
        )

      result = @client.add_torrent("http://example.com/test.nzb")
      assert_not result
    end
  end

  test "list_torrents returns queue and history items" do
    VCR.turned_off do
      # Stub listgroups (queue)
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "listgroups"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              {
                "NZBID" => 1001,
                "NZBName" => "Test Download",
                "Status" => "DOWNLOADING",
                "FileSizeMB" => 1024,
                "RemainingSizeMB" => 512,
                "DestDir" => "/downloads/incomplete"
              }
            ]
          }.to_json
        )

      # Stub history
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "history"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              {
                "NZBID" => 1000,
                "Name" => "Completed Download",
                "Status" => "SUCCESS",
                "FileSizeMB" => 2048,
                "DestDir" => "/downloads/complete/Completed Download"
              }
            ]
          }.to_json
        )

      torrents = @client.list_torrents

      assert_kind_of Array, torrents
      assert_equal 2, torrents.size

      queue_item = torrents.find { |t| t.hash == "1001" }
      assert_equal "Test Download", queue_item.name
      assert_equal 50, queue_item.progress
      assert_equal :downloading, queue_item.state

      history_item = torrents.find { |t| t.hash == "1000" }
      assert_equal "Completed Download", history_item.name
      assert_equal 100, history_item.progress
      assert_equal :completed, history_item.state
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "version"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "21.1" }.to_json
        )

      assert @client.test_connection
    end
  end

  test "test_connection returns false on auth failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(basic_auth: [ "nzbget", "tegbzn6789" ])
        .to_return(status: 401)

      assert_not @client.test_connection
    end
  end

  test "test_connection returns false on connection error" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(basic_auth: [ "nzbget", "tegbzn6789" ])
        .to_timeout

      assert_not @client.test_connection
    end
  end

  test "torrent_info returns item from queue" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "listgroups"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              {
                "NZBID" => 999,
                "NZBName" => "Test Item",
                "Status" => "DOWNLOADING",
                "FileSizeMB" => 1000,
                "RemainingSizeMB" => 250,
                "DestDir" => "/downloads"
              }
            ]
          }.to_json
        )

      info = @client.torrent_info("999")

      assert_not_nil info
      assert_equal "999", info.hash
      assert_equal "Test Item", info.name
      assert_equal 75, info.progress
      assert_equal :downloading, info.state
    end
  end

  test "torrent_info returns item from history when not in queue" do
    VCR.turned_off do
      # Queue returns empty
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "listgroups"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => [] }.to_json
        )

      # History returns the item
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "history"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              {
                "NZBID" => 888,
                "Name" => "Completed Item",
                "Status" => "SUCCESS",
                "FileSizeMB" => 500,
                "DestDir" => "/downloads/complete"
              }
            ]
          }.to_json
        )

      info = @client.torrent_info("888")

      assert_not_nil info
      assert_equal "888", info.hash
      assert_equal "Completed Item", info.name
      assert_equal :completed, info.state
    end
  end

  test "remove_torrent removes from queue" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(
          body: hash_including("method" => "editqueue"),
          basic_auth: [ "nzbget", "tegbzn6789" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => true }.to_json
        )

      assert @client.remove_torrent("12345")
    end
  end

  test "normalizes queue states correctly" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(body: hash_including("method" => "listgroups"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              { "NZBID" => 1, "NZBName" => "Downloading", "Status" => "DOWNLOADING", "FileSizeMB" => 100, "RemainingSizeMB" => 50, "DestDir" => "" },
              { "NZBID" => 2, "NZBName" => "Paused", "Status" => "PAUSED", "FileSizeMB" => 100, "RemainingSizeMB" => 50, "DestDir" => "" },
              { "NZBID" => 3, "NZBName" => "Queued", "Status" => "QUEUED", "FileSizeMB" => 100, "RemainingSizeMB" => 100, "DestDir" => "" },
              { "NZBID" => 4, "NZBName" => "PostProcessing", "Status" => "UNPACKING", "FileSizeMB" => 100, "RemainingSizeMB" => 0, "DestDir" => "" }
            ]
          }.to_json
        )

      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(body: hash_including("method" => "history"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => [] }.to_json
        )

      torrents = @client.list_torrents

      assert_equal :downloading, torrents.find { |t| t.hash == "1" }.state
      assert_equal :paused, torrents.find { |t| t.hash == "2" }.state
      assert_equal :queued, torrents.find { |t| t.hash == "3" }.state
      assert_equal :queued, torrents.find { |t| t.hash == "4" }.state  # post-processing is queued
    end
  end

  test "normalizes history states correctly" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(body: hash_including("method" => "listgroups"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => [] }.to_json
        )

      stub_request(:post, "http://localhost:6789/jsonrpc")
        .with(body: hash_including("method" => "history"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => [
              { "NZBID" => 1, "Name" => "Success", "Status" => "SUCCESS", "FileSizeMB" => 100, "DestDir" => "" },
              { "NZBID" => 2, "Name" => "Failed", "Status" => "FAILURE", "FileSizeMB" => 100, "DestDir" => "" },
              { "NZBID" => 3, "Name" => "Deleted", "Status" => "DELETED", "FileSizeMB" => 100, "DestDir" => "" }
            ]
          }.to_json
        )

      torrents = @client.list_torrents

      assert_equal :completed, torrents.find { |t| t.hash == "1" }.state
      assert_equal :failed, torrents.find { |t| t.hash == "2" }.state
      assert_equal :failed, torrents.find { |t| t.hash == "3" }.state
    end
  end
end
