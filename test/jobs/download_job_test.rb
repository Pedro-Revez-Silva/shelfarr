# frozen_string_literal: true

require "test_helper"
require "base64"
require "bencode"
require "digest/sha1"

class DownloadJobTest < ActiveJob::TestCase
  setup do
    DownloadClient.destroy_all
    @request = requests(:pending_request)
    @selected_result = search_results(:selected_result)

    # Create a qBittorrent client
    @client = DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )

    # Clear qBittorrent sessions
    Thread.current[:qbittorrent_sessions] = {}
    Thread.current[:transmission_protocols] = {}
    ZLibraryClient.reset_auth_cache! if defined?(ZLibraryClient)

    # Create a queued download
    @download = @request.downloads.create!(
      name: @selected_result.title,
      size_bytes: @selected_result.size_bytes,
      status: :queued
    )
  end

  test "updates download status to downloading on success" do
    VCR.turned_off do
      stub_qbittorrent_success

      DownloadJob.perform_now(@download.id)
      @download.reload

      assert @download.downloading?
      assert_equal @client.id.to_s, @download.download_client_id
      # Hash is computed from the test torrent file
      assert @download.external_id.present?, "external_id should be set"
      assert_match(/^[a-f0-9]{40}$/, @download.external_id, "external_id should be a SHA1 hash")
    end
  end

  test "marks for attention when no search result selected" do
    # Remove the selected result
    @request.search_results.selected.destroy_all

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search result selected"
  end

  test "marks for attention when result has no download link" do
    # Replace selected with no-link result
    @request.search_results.selected.destroy_all
    no_link = search_results(:no_link_result)
    no_link.update!(status: :selected)

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "no download link"
  end

  test "marks for attention when no download client configured" do
    @client.destroy!

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No torrent download client configured"
  end

  test "skips non-queued downloads" do
    @download.update!(status: :downloading)

    DownloadJob.perform_now(@download.id)
    @download.reload

    # Status should not change
    assert @download.downloading?
  end

  test "uses transmission client for torrent downloads" do
    @client.destroy!
    transmission = DownloadClient.create!(
      name: "Test Transmission",
      client_type: "transmission",
      url: "http://localhost:9091",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    Thread.current[:transmission_sessions] = {}
    Thread.current[:transmission_protocols] = {}
    torrent_data = {
      "info" => {
        "name" => "Transmission Book.epub",
        "piece length" => 16384,
        "pieces" => "s" * 20,
        "length" => 512
      }
    }.bencode
    @selected_result.update!(download_url: "http://prowlarr:9696/api/v1/indexer/download/123")

    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "session_get" &&
            body["params"] == {} &&
            body["id"] == 1
        end
        .to_return(
          {
            status: 409,
            headers: { "x-transmission-session-id" => "session-id" },
            body: { "result" => "session", "arguments" => {} }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "jsonrpc" => "2.0", "result" => { "version" => "4.1.1" }, "id" => 1 }.to_json
          }
        )
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer/download/123")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "torrent_get" &&
            body["params"] == { "ids" => "all", "fields" => [ "hash_string" ] } &&
            body["id"] == 1
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [] }, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "torrent_add" &&
            body["params"]["metainfo"] == Base64.strict_encode64(torrent_data) &&
            !body["params"].key?("filename") &&
            body["id"] == 1
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrent_added" => { "hash_string" => "transmission-hash" } }, "id" => 1 }.to_json
        )

      DownloadJob.perform_now(@download.id)
      @download.reload

      assert @download.downloading?
      assert_equal transmission.id.to_s, @download.download_client_id
      assert_equal "transmission-hash", @download.external_id
      assert_equal "torrent", @download.download_type
    end
  end

  test "skips non-existent downloads" do
    assert_nothing_raised do
      DownloadJob.perform_now(999999)
    end
  end

  # Tests for filename handling (URL decoding and sanitization)

  test "sanitize_filename decodes URL-encoded characters" do
    job = DownloadJob.new
    url = "https://example.com/download/Moonshot%20%3A%20inside%20Pfizer%27s%20book.epub"

    filename = job.send(:infer_filename_from_url, url, @selected_result)

    # Should decode %20 to space, %3A to colon, %27 to apostrophe
    assert_includes filename, "Moonshot"
    assert_not_includes filename, "%20"
    assert_not_includes filename, "%3A"
    assert_not_includes filename, "%27"
    assert filename.end_with?(".epub")
  end

  test "sanitize_filename preserves extension when truncating long filenames" do
    job = DownloadJob.new

    # Create a filename that's over 200 characters
    long_name = "A" * 250 + ".epub"
    result = job.send(:sanitize_filename, long_name)

    assert result.length <= 200
    assert result.end_with?(".epub"), "Extension should be preserved after truncation"
  end

  test "sanitize_filename handles filenames under max length" do
    job = DownloadJob.new

    short_name = "Short Book Title.epub"
    result = job.send(:sanitize_filename, short_name)

    assert_equal "Short Book Title.epub", result
  end

  test "sanitize_filename removes invalid characters" do
    job = DownloadJob.new

    name_with_invalid = "Book: A \"Test\" Title?.epub"
    result = job.send(:sanitize_filename, name_with_invalid)

    assert_not_includes result, ":"
    assert_not_includes result, "\""
    assert_not_includes result, "?"
    assert result.end_with?(".epub")
  end

  test "infer_filename_from_url falls back to book metadata when URL has no extension" do
    job = DownloadJob.new
    url = "https://example.com/download/some-file-without-extension"

    filename = job.send(:infer_filename_from_url, url, @selected_result)

    # Should fall back to author - title format
    book = @selected_result.request.book
    assert_includes filename, book.author
    assert_includes filename, book.title
    assert filename.end_with?(".epub") || filename.end_with?(".pdf") || filename.end_with?(".mobi")
  end

  test "zlibrary download completes via eAPI" do
    VCR.turned_off do
      setup_zlibrary_download

      stub_zlibrary_login
      stub_zlibrary_download_api
      stub_request(:get, "https://download.z-library.bz/dl/book999/file.epub")
        .to_return(status: 200, body: "PK\x03\x04" + "x" * 2000, headers: { "Content-Type" => "application/epub+zip" })

      DownloadJob.perform_now(@zlib_download.id)
      @zlib_download.reload

      assert @zlib_download.completed?
    end
  end

  test "zlibrary download fails on auth error" do
    VCR.turned_off do
      setup_zlibrary_download

      %w[z-library.bz 1lib.sk z-lib.fm z-lib.sk].each do |domain|
        stub_request(:post, "https://#{domain}/eapi/user/login")
          .to_return(status: 500, body: "Server Error")
      end

      DownloadJob.perform_now(@zlib_download.id)
      @zlib_download.reload

      assert @zlib_download.failed?
    end
  end

  test "zlibrary download rejects HTML error page" do
    VCR.turned_off do
      setup_zlibrary_download

      stub_zlibrary_login
      stub_zlibrary_download_api
      stub_request(:get, "https://download.z-library.bz/dl/book999/file.epub")
        .to_return(status: 200, body: "<html><body>Error</body></html>", headers: { "Content-Type" => "text/html" })

      DownloadJob.perform_now(@zlib_download.id)
      @zlib_download.reload

      assert @zlib_download.failed?
    end
  end

  private

  def stub_qbittorrent_success
    # Create a valid torrent file for hash extraction
    info_dict = {
      "name" => "Test Torrent",
      "piece length" => 16384,
      "pieces" => "x" * 20,
      "length" => 1000
    }
    torrent_data = { "info" => info_dict }.bencode
    # The hash will be SHA1 of the bencoded info dict
    # We use a fixed hash in the test since we control the torrent data
    expected_hash = Digest::SHA1.hexdigest(info_dict.bencode).downcase

    # Stub torrent file download (used for hash extraction)
    stub_request(:get, "http://example.com/download/test.torrent")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/x-bittorrent" },
        body: torrent_data
      )

    # Stub authentication and version endpoint
    stub_qbittorrent_connection("http://localhost:8080")

    # Stub add torrent
    stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
      .to_return(status: 200, body: "Ok.")

    # Note: With pre-computed hash, we should NOT need to poll for torrent info
    # But stub it anyway in case fallback is triggered
    stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [{ "hash" => expected_hash, "name" => "Test Torrent", "progress" => 0, "state" => "downloading", "size" => 1000, "content_path" => "/downloads/Test Torrent" }].to_json
      )
  end

  def setup_zlibrary_download
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")
    SettingsService.set(:ebook_output_path, Dir.tmpdir)

    zlib_result = @request.search_results.create!(
      guid: "999:deadbeef",
      title: "Z-Library Book [EPUB]",
      indexer: "Z-Library",
      source: SearchResult::SOURCE_ZLIBRARY,
      status: :selected
    )
    @request.search_results.where.not(id: zlib_result.id).update_all(status: :pending)

    @zlib_download = @request.downloads.create!(
      name: zlib_result.title,
      size_bytes: 1_000_000,
      status: :queued
    )
    @download.update!(status: :completed)
  end

  def stub_zlibrary_login
    stub_request(:post, "https://z-library.bz/eapi/user/login")
      .to_return(
        status: 200,
        body: { success: 1, user: { id: "12345", remix_userkey: "abcdef123456" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_download_api
    stub_request(:get, "https://z-library.bz/eapi/book/999/deadbeef/file")
      .to_return(
        status: 200,
        body: {
          success: 1,
          file: { downloadLink: "https://download.z-library.bz/dl/book999/file.epub" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
