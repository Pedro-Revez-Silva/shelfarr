# frozen_string_literal: true

require "test_helper"

class DownloadClients::DecypharrTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test Decypharr",
      client_type: "decypharr",
      url: "http://localhost:8282",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter

    Thread.current[:qbittorrent_sessions] = {}
  end

  test "authenticates with lowercase sid cookie" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )

      add_stub = stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .with(headers: { "Cookie" => "sid=test_session_id" })
        .to_return(status: 200, body: "Ok.")

      stub_request(:get, "http://localhost:8282/api/v2/torrents/info?hashes=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        .with(headers: { "Cookie" => "sid=test_session_id" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "name" => "Test", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")

      assert_equal "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", result
      assert_requested(add_stub)
    end
  end

  test "adds torrents with sequential download flag" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )

      add_stub = stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .with(body: hash_including("urls" => "magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "sequentialDownload" => "true"))
        .to_return(status: 200, body: "Ok.")

      stub_request(:get, "http://localhost:8282/api/v2/torrents/info?hashes=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "name" => "Test", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )

      @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")

      assert_requested(add_stub)
    end
  end

  test "uploads torrent files with sequential download flag" do
    VCR.turned_off do
      info_dict = {
        "name" => "Decypharr Book.epub",
        "piece length" => 16384,
        "pieces" => "s" * 20,
        "length" => 512
      }
      torrent_data = { "info" => info_dict }.bencode
      expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )

      stub_request(:get, "http://prowlarr:9696/api/v1/indexer/download/123")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )

      add_stub = stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .with do |request|
          request.body.include?("name=\"sequentialDownload\"") &&
            request.body.include?("true")
        end
        .to_return(status: 200, body: "Ok.")

      stub_request(:get, "http://localhost:8282/api/v2/torrents/info?hashes=#{expected_hash}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash, "name" => "Decypharr Book.epub", "progress" => 0, "state" => "downloading", "size" => 512, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("http://prowlarr:9696/api/v1/indexer/download/123")

      assert_equal expected_hash, result
      assert_requested(add_stub)
    end
  end
end
