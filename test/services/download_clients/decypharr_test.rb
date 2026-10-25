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

  test "authenticates with lowercase sid cookie when generic API key is stored" do
    VCR.turned_off do
      @client_record.update!(api_key: "not_supported_by_qbit_compatibility_api")

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

  test "adds magnet torrents without sequential download flag" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )

      add_stub = stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .with do |request|
          params = URI.decode_www_form(request.body).to_h
          params["urls"] == "magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" &&
            !params.key?("sequentialDownload")
        end
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

  test "uploads torrent files without sequential download flag" do
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
          request.headers["Content-Type"]&.include?("multipart/form-data") &&
            request.body.include?("name=\"torrents\"") &&
            !request.body.include?("name=\"sequentialDownload\"")
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

  test "add_torrent raises ConnectionError for a transient Decypharr API outage" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )
      stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .to_return(
          status: 503,
          headers: { "Content-Type" => "application/json" },
          body: { "error" => "unavailable" }.to_json
        )

      error = assert_raises(DownloadClients::Base::ConnectionError) do
        @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
      end
      assert_instance_of DownloadClients::Base::ConnectionError, error
      assert_equal "qBittorrent API error: 503", error.message
    end
  end

  test "refuses to add an unhashed torrent before submission" do
    torrent_url = "http://indexer.example/download/1"
    foreign_hash = "f" * 40
    add_request = nil

    VCR.turned_off do
      stub_request(:post, "http://localhost:8282/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "sid=test_session_id; path=/" },
          body: "Ok."
        )
      stub_request(:get, "http://localhost:8282/api/v2/app/webapiVersion")
        .to_return(status: 200, body: "2.11.0")
      stub_request(:get, torrent_url).to_return(status: 403, body: "no")
      add_request = stub_request(:post, "http://localhost:8282/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")
      stub_request(:get, %r{localhost:8282/api/v2/torrents/info})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => foreign_hash, "name" => "Foreign" } ].to_json
        )

      result = nil
      error = nil
      begin
        result = @client.stub(:sleep, nil) { @client.add_torrent(torrent_url) }
      rescue DownloadClients::Base::Error => caught
        error = caught
      end

      assert error, "expected a configuration error before adding, got #{result.inspect}"
      assert_match(/Decypharr/, error.message)
      assert_match(/tag/i, error.message)
      assert_not_requested add_request
      refute_equal foreign_hash, result
    end
  end
end
