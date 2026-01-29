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

      # Stub verification - torrent info returns the added torrent
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "name" => "Test", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )

      # Use valid hex hash in magnet link
      result = @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
      assert_equal "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", result
    end
  end

  test "add_torrent falls back to polling when torrent file cannot be downloaded" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download - connection fails (simulates network issue)
      stub_request(:get, "http://example.com/file.torrent")
        .to_timeout

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub torrent info - first call returns empty (before adding),
      # subsequent calls return the new torrent (after adding)
      stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [ { "hash" => "def456abc789" } ].to_json }
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
              "content_path" => "/downloads/Test Torrent"
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

      stub_request(:get, "http://localhost:8080/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")

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

  test "test_connection returns false when API endpoint returns 404" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Simulates seedbox subpath issue where auth works but API returns 404
      stub_request(:get, "http://localhost:8080/api/v2/app/version")
        .to_return(status: 404, body: "<html><head><title>404 Not Found</title></head></html>")

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

  test "parse_torrent falls back to save_path + name when content_path is missing" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent info without content_path (older qBittorrent versions)
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "hash" => "abc123def456",
              "name" => "Test Torrent",
              "progress" => 1.0,
              "state" => "uploading",
              "size" => 1073741824,
              "save_path" => "/downloads/category"
            }
          ].to_json
        )

      torrents = @client.list_torrents

      assert_equal 1, torrents.size
      torrent = torrents.first
      # Should fall back to save_path + name
      assert_equal "/downloads/category/Test Torrent", torrent.download_path
    end
  end

  # === Hash Extraction Tests (Race Condition Fix) ===

  test "add_torrent extracts hash from downloaded torrent file" do
    VCR.turned_off do
      # Create a valid bencoded torrent file
      info_dict = {
        "name" => "Test Book.epub",
        "piece length" => 16384,
        "pieces" => "12345678901234567890", # 20 bytes (1 SHA1 hash)
        "length" => 1024
      }
      torrent_data = { "info" => info_dict }.bencode

      # Calculate expected hash (SHA1 of bencoded info dict)
      expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download - this should be called BEFORE adding to qBittorrent
      stub_request(:get, "http://tracker.example.com/download/123.torrent")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification - torrent info returns the added torrent
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash, "name" => "Test Book.epub", "progress" => 0, "state" => "downloading", "size" => 1024, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("http://tracker.example.com/download/123.torrent")

      assert_equal expected_hash, result
      # Verify torrent file was downloaded
      assert_requested(:get, "http://tracker.example.com/download/123.torrent")
    end
  end

  test "add_torrent extracts hash from torrent URL with query parameters" do
    VCR.turned_off do
      # Create a valid bencoded torrent file
      info_dict = {
        "name" => "Another Book.epub",
        "piece length" => 16384,
        "pieces" => "abcdefghijklmnopqrst", # 20 bytes
        "length" => 2048
      }
      torrent_data = { "info" => info_dict }.bencode
      expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download with query params (common for private trackers)
      stub_request(:get, "http://tracker.example.com/download.php?id=456&passkey=abc123")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification - torrent info returns the added torrent
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash, "name" => "Another Book.epub", "progress" => 0, "state" => "downloading", "size" => 2048, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("http://tracker.example.com/download.php?id=456&passkey=abc123")

      assert_equal expected_hash, result
    end
  end

  test "add_torrent falls back to polling when torrent download fails" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download - fails with 404
      stub_request(:get, "http://tracker.example.com/download/missing.torrent")
        .to_return(status: 404, body: "Not Found")

      # Since torrent download failed, it should capture existing hashes first
      # First call: get existing hashes (empty)
      # Second call: after adding, find new hash
      stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [ { "hash" => "fallback123" } ].to_json }
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      result = @client.add_torrent("http://tracker.example.com/download/missing.torrent")

      # Should fall back to polling and find the hash
      assert_equal "fallback123", result
    end
  end

  test "add_torrent falls back to polling when torrent file is invalid" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download - returns invalid data (not bencode)
      stub_request(:get, "http://tracker.example.com/download/invalid.torrent")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "text/html" },
          body: "<html>Login required</html>"
        )

      # Should fall back to polling
      stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [ { "hash" => "polled456" } ].to_json }
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      result = @client.add_torrent("http://tracker.example.com/download/invalid.torrent")

      assert_equal "polled456", result
    end
  end

  test "add_torrent handles torrent file without info dict" do
    VCR.turned_off do
      # Create an invalid torrent file (missing info dict)
      torrent_data = { "announce" => "http://tracker.example.com/announce" }.bencode

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent file download
      stub_request(:get, "http://tracker.example.com/download/noinfo.torrent")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )

      # Should fall back to polling
      stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [ { "hash" => "noinfo789" } ].to_json }
        )

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      result = @client.add_torrent("http://tracker.example.com/download/noinfo.torrent")

      assert_equal "noinfo789", result
    end
  end

  test "add_torrent verifies torrent exists after adding with pre-computed hash" do
    VCR.turned_off do
      # Create a valid torrent file
      info_dict = { "name" => "Book.epub", "piece length" => 16384, "pieces" => "x" * 20, "length" => 100 }
      torrent_data = { "info" => info_dict }.bencode
      expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent download
      stub_request(:get, "http://tracker.example.com/file.torrent")
        .to_return(status: 200, body: torrent_data)

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification - torrent info is called to verify the torrent exists
      info_stub = stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash, "name" => "Book.epub", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("http://tracker.example.com/file.torrent")

      assert_equal expected_hash, result
      # Verify that torrent info was called to verify the torrent exists
      assert_requested(info_stub, times: 1)
    end
  end

  test "concurrent add_torrent calls get different hashes when pre-computed" do
    VCR.turned_off do
      # Create two different torrent files
      info_dict_a = { "name" => "Book A.epub", "piece length" => 16384, "pieces" => "a" * 20, "length" => 100 }
      info_dict_b = { "name" => "Book B.epub", "piece length" => 16384, "pieces" => "b" * 20, "length" => 200 }
      torrent_data_a = { "info" => info_dict_a }.bencode
      torrent_data_b = { "info" => info_dict_b }.bencode
      expected_hash_a = Digest::SHA1.hexdigest(info_dict_a.bencode).downcase
      expected_hash_b = Digest::SHA1.hexdigest(info_dict_b.bencode).downcase

      # Sanity check - hashes should be different
      assert_not_equal expected_hash_a, expected_hash_b

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub torrent downloads
      stub_request(:get, "http://tracker.example.com/book_a.torrent")
        .to_return(status: 200, body: torrent_data_a)
      stub_request(:get, "http://tracker.example.com/book_b.torrent")
        .to_return(status: 200, body: torrent_data_b)

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification for both torrents
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash_a}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash_a, "name" => "Book A.epub", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash_b}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash_b, "name" => "Book B.epub", "progress" => 0, "state" => "downloading", "size" => 200, "content_path" => "/downloads" } ].to_json
        )

      # Simulate concurrent calls - each should get its own correct hash
      result_a = @client.add_torrent("http://tracker.example.com/book_a.torrent")
      result_b = @client.add_torrent("http://tracker.example.com/book_b.torrent")

      assert_equal expected_hash_a, result_a, "First torrent should get hash A"
      assert_equal expected_hash_b, result_b, "Second torrent should get hash B"
      assert_not_equal result_a, result_b, "Hashes should be different"
    end
  end

  test "add_torrent follows redirects when downloading torrent file" do
    VCR.turned_off do
      info_dict = { "name" => "Redirect Book.epub", "piece length" => 16384, "pieces" => "r" * 20, "length" => 100 }
      torrent_data = { "info" => info_dict }.bencode
      expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub redirect chain
      stub_request(:get, "http://tracker.example.com/download/redirect.torrent")
        .to_return(status: 302, headers: { "Location" => "http://cdn.example.com/actual.torrent" })
      stub_request(:get, "http://cdn.example.com/actual.torrent")
        .to_return(status: 200, body: torrent_data)

      # Stub add torrent
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=#{expected_hash}")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "hash" => expected_hash, "name" => "Redirect Book.epub", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json
        )

      result = @client.add_torrent("http://tracker.example.com/download/redirect.torrent")

      assert_equal expected_hash, result
    end
  end

  # === Verification Tests (Issue #114 Fix) ===

  test "add_torrent returns nil when verification fails (torrent rejected by qBittorrent)" do
    VCR.turned_off do
      # Stub authentication
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
          body: "Ok."
        )

      # Stub add torrent - qBittorrent returns "Ok." even when it fails silently
      stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
        .to_return(status: 200, body: "Ok.")

      # Stub verification - torrent not found (qBittorrent rejected it)
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")

      # Should return nil because verification failed
      assert_nil result
    end
  end

  test "add_torrent retries verification when torrent takes time to appear" do
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

      # Stub verification - first call returns empty, second call returns the torrent
      stub_request(:get, "http://localhost:8080/api/v2/torrents/info?hashes=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        .to_return(
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: [ { "hash" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "name" => "Test", "progress" => 0, "state" => "downloading", "size" => 100, "content_path" => "/downloads" } ].to_json }
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")

      # Should succeed on second verification attempt
      assert_equal "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", result
    end
  end
end
