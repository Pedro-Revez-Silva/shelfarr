# frozen_string_literal: true

require "test_helper"

class DownloadClients::SabnzbdTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key-12345",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter
  end

  test "add_torrent adds NZB successfully" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=addurl})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => true, "nzo_ids" => ["SABnzbd_nzo_12345"] }.to_json
        )

      result = @client.add_torrent("http://example.com/test.nzb")
      assert result
    end
  end

  test "add_torrent passes nzbname when provided" do
    VCR.turned_off do
      request_stub = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including(
          "mode" => "addurl",
          "name" => "http://example.com/test.nzb",
          "nzbname" => "Another Author - The Pending Ebook",
          "apikey" => "test-api-key-12345",
          "output" => "json"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => true, "nzo_ids" => ["SABnzbd_nzo_12345"] }.to_json
        )

      result = @client.add_torrent("http://example.com/test.nzb", nzbname: "Another Author - The Pending Ebook")

      assert result
      assert_requested request_stub
    end
  end

  test "list_torrents returns queue and history items" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=queue})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "queue" => {
              "slots" => [
                {
                  "nzo_id" => "SABnzbd_nzo_queue1",
                  "filename" => "Test Download",
                  "percentage" => 50,
                  "status" => "Downloading",
                  "mb" => "1024",
                  "storage" => "/downloads/incomplete"
                }
              ]
            }
          }.to_json
        )

      stub_request(:get, %r{localhost:8080/api.*mode=history})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "history" => {
              "slots" => [
                {
                  "nzo_id" => "SABnzbd_nzo_hist1",
                  "name" => "Completed Download",
                  "status" => "Completed",
                  "bytes" => 1073741824,
                  "storage" => "/downloads/complete/Completed Download"
                }
              ]
            }
          }.to_json
        )

      torrents = @client.list_torrents

      assert_kind_of Array, torrents
      assert_equal 2, torrents.size

      queue_item = torrents.find { |t| t.hash == "SABnzbd_nzo_queue1" }
      assert_equal "Test Download", queue_item.name
      assert_equal 50, queue_item.progress
      assert_equal :downloading, queue_item.state

      history_item = torrents.find { |t| t.hash == "SABnzbd_nzo_hist1" }
      assert_equal "Completed Download", history_item.name
      assert_equal 100, history_item.progress
      assert_equal :completed, history_item.state
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=version})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "version" => "4.0.0" }.to_json
        )

      assert @client.test_connection
    end
  end

  test "test_connection returns false on failure" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=version})
        .to_return(status: 401)

      assert_not @client.test_connection
    end
  end

  test "torrent_info returns item from queue" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=queue})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "queue" => {
              "slots" => [
                {
                  "nzo_id" => "test_nzo_id",
                  "filename" => "Test Item",
                  "percentage" => 75,
                  "status" => "Downloading",
                  "mb" => "500",
                  "storage" => "/downloads"
                }
              ]
            }
          }.to_json
        )

      info = @client.torrent_info("test_nzo_id")

      assert_not_nil info
      assert_equal "test_nzo_id", info.hash
      assert_equal "Test Item", info.name
      assert_equal 75, info.progress
    end
  end
end
