# frozen_string_literal: true

require "test_helper"
require "base64"
require "bencode"
require "digest/sha1"
require "securerandom"
require "tempfile"

class DownloadJobTest < ActiveJob::TestCase
  setup do
    AudiobookProbeService.probe = ->(_path) { true }
    DownloadClient.destroy_all
    @request = requests(:pending_request)
    @selected_result = search_results(:selected_result)
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")

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
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)

    # Create a queued download
    @download = @request.downloads.create!(
      name: @selected_result.title,
      size_bytes: @selected_result.size_bytes,
      search_result: @selected_result,
      status: :queued
    )
  end

  teardown do
    AudiobookProbeService.reset_probe!
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)
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
    @download.update!(search_result: nil)
    @request.search_results.selected.destroy_all

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search result selected"
  end

  test "marks for attention when result has no download link" do
    no_link = search_results(:no_link_result)
    @download.update!(search_result: no_link)

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "no download link"
  end

  test "uses the download search result instead of the current selected result" do
    no_link = search_results(:no_link_result)
    @download.update!(search_result: no_link)

    DownloadJob.perform_now(@download.id)
    @download.reload

    assert @download.failed?
  end

  test "falls back to selected result for existing downloads without association" do
    @download.update!(search_result: nil)

    VCR.turned_off do
      stub_qbittorrent_success

      DownloadJob.perform_now(@download.id)
      @download.reload

      assert @download.downloading?
      assert_equal @selected_result, @download.search_result
    end
  end

  test "legacy download without association blocklists resolved selected result on release failure" do
    SettingsService.set(:auto_select_enabled, false)
    @download.update!(search_result: nil)
    job = DownloadJob.new

    job.stub(:handle_standard_download, ->(*) { raise DownloadClients::Base::Error, "client rejected release" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_equal @selected_result, @download.search_result
    assert @selected_result.reload.blocklisted?
  end

  test "marks for attention when no download client configured" do
    @client.destroy!

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No torrent download client configured"
    assert_not @selected_result.reload.blocklisted?
  end

  test "marks for attention on download client authentication error" do
    job = DownloadJob.new

    job.stub(:handle_standard_download, ->(*) { raise DownloadClients::Base::AuthenticationError, "bad credentials" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_includes @request.reload.issue_description, "authentication failed"
    assert_not @selected_result.reload.blocklisted?
  end

  test "marks for attention on download client connection error" do
    job = DownloadJob.new

    job.stub(:handle_standard_download, ->(*) { raise DownloadClients::Base::ConnectionError, "offline" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_includes @request.reload.issue_description, "Failed to connect"
    assert_not @selected_result.reload.blocklisted?
  end

  test "marks for attention on generic download client error" do
    job = DownloadJob.new

    job.stub(:handle_standard_download, ->(*) { raise DownloadClients::Base::Error, "client boom" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_includes @request.reload.issue_description, "Download client error"
    assert @selected_result.reload.blocklisted?
  end

  test "generic download client error blocklists release and selects next candidate when auto-select is enabled" do
    SettingsService.set(:auto_select_enabled, true)
    SettingsService.set(:auto_select_confidence_threshold, 50)
    SettingsService.set(:auto_select_min_seeders, 1)
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    fallback = search_results(:pending_result)
    fallback.update!(confidence_score: 95, detected_language: "en")
    job = DownloadJob.new

    assert_enqueued_with(job: DownloadJob) do
      job.stub(:handle_standard_download, ->(*) { raise DownloadClients::Base::Error, "client rejected release" }) do
        job.perform(@download.id)
      end
    end

    assert @download.reload.failed?
    assert @selected_result.reload.blocklisted?
    assert fallback.reload.selected?
    assert @request.reload.downloading?
    assert_not @request.attention_needed?
  end

  test "marks for attention on anna archive error" do
    @selected_result.update!(source: SearchResult::SOURCE_ANNA_ARCHIVE, guid: "md5")
    job = DownloadJob.new

    job.stub(:handle_anna_archive_download, ->(*) { raise AnnaArchiveClient::Error, "anna boom" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_includes @request.reload.issue_description, "Anna's Archive error"
  end

  test "does not blocklist on Anna's Archive transient connection error" do
    @selected_result.update!(source: SearchResult::SOURCE_ANNA_ARCHIVE, guid: "md5")
    job = DownloadJob.new

    job.stub(:handle_anna_archive_download, ->(*) { raise AnnaArchiveClient::ConnectionError, "offline" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_not @selected_result.reload.blocklisted?
  end

  test "does not blocklist on Anna's Archive direct audiobook transient download error" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir)

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/anna-audiobook.zip" do
          stub_request(:get, "https://files.test/anna-audiobook.zip")
            .to_return(status: 503, body: "Unavailable")

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert @anna_archive_audiobook_request.reload.attention_needed?
      assert_includes @anna_archive_audiobook_request.issue_description, "Anna's Archive download failed"
      assert_not @anna_archive_audiobook_download.search_result.reload.blocklisted?
    end
  end

  test "marks for attention on z-library error" do
    @selected_result.update!(source: SearchResult::SOURCE_ZLIBRARY, guid: "missing")
    job = DownloadJob.new

    job.stub(:handle_zlibrary_download, ->(*) { raise ZLibraryClient::Error, "z boom" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert_includes @request.reload.issue_description, "Z-Library error"
  end

  test "does not blocklist on Z-Library rate limit error" do
    @selected_result.update!(source: SearchResult::SOURCE_ZLIBRARY, guid: "missing")
    job = DownloadJob.new

    job.stub(:handle_zlibrary_download, ->(*) { raise ZLibraryClient::RateLimitError, "slow down" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_not @selected_result.reload.blocklisted?
  end

  test "does not blocklist on LibriVox transient connection error" do
    @selected_result.update!(
      source: SearchResult::SOURCE_LIBRIVOX,
      download_url: "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3"
    )
    job = DownloadJob.new

    job.stub(:handle_librivox_download, ->(*) { raise LibrivoxClient::ConnectionError, "offline" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_not @selected_result.reload.blocklisted?
  end

  test "does not blocklist on transient direct download network error" do
    Dir.mktmpdir do |dir|
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Transient Direct Ebook",
        author: "Network Author",
        book_type: :ebook
      )
      request = Request.create!(book: book, user: users(:one), status: :downloading)
      download_url = "https://example.com/#{SecureRandom.hex(8)}.epub"
      result = request.search_results.create!(
        guid: "gutenberg-timeout-#{SecureRandom.hex(8)}",
        title: "Transient Direct Ebook - Network Author [EPUB]",
        indexer: "Project Gutenberg",
        source: SearchResult::SOURCE_GUTENBERG,
        download_url: download_url,
        status: :selected
      )
      download = request.downloads.create!(
        name: result.title,
        search_result: result,
        status: :queued
      )

      VCR.turned_off do
        stub_request(:get, download_url)
          .to_raise(Timeout::Error.new("execution expired"))

        DownloadJob.perform_now(download.id)
      end

      assert download.reload.failed?
      assert request.reload.attention_needed?
      result.reload
      request.reload
      assert_not result.blocklisted?,
        "expected transient direct timeout not to blocklist; " \
        "blocklist_reason=#{result.blocklist_reason.inspect}; issue=#{request.issue_description.inspect}"
    end
  end

  test "does not blocklist on LibriVox direct audiobook transient download error" do
    Dir.mktmpdir do |dir|
      setup_librivox_download(output_path: dir)

      VCR.turned_off do
        stub_request(:get, "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3")
          .to_timeout

        DownloadJob.perform_now(@librivox_download.id)
      end

      @librivox_download.reload
      @librivox_request.reload
      assert @librivox_download.failed?
      assert @librivox_request.attention_needed?
      assert_includes @librivox_request.issue_description, "LibriVox download failed"
      assert_not @librivox_download.search_result.reload.blocklisted?
    end
  end

  test "does not blocklist on custom provider direct audiobook transient download error" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_audiobook_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "https://files.test/custom-audiobook.m4b" }.to_json
          )

        stub_request(:get, "https://files.test/custom-audiobook.m4b")
          .to_timeout

        DownloadJob.perform_now(@custom_provider_audiobook_download.id)
      end

      @custom_provider_audiobook_download.reload
      @custom_provider_audiobook_request.reload
      assert @custom_provider_audiobook_download.failed?
      assert @custom_provider_audiobook_request.attention_needed?
      assert_includes @custom_provider_audiobook_request.issue_description, "Custom provider download failed"
      assert_not @custom_provider_audiobook_download.search_result.reload.blocklisted?
    end
  end

  test "does not blocklist on custom provider system response error" do
    @selected_result.update!(source: SearchResult::SOURCE_CUSTOM)
    job = DownloadJob.new

    job.stub(:handle_custom_provider_download, ->(*) { raise CustomAcquisitionProviderClient::ResponseError, "Provider returned HTTP 500" }) do
      job.perform(@download.id)
    end

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_not @selected_result.reload.blocklisted?
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

  test "uses book metadata as usenet job name for sabnzbd" do
    @client.destroy!
    sabnzbd = DownloadClient.create!(
      name: "Test SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key-12345",
      priority: 0,
      enabled: true
    )
    @selected_result.update!(
      magnet_url: nil,
      download_url: "http://prowlarr:9696/11/download?apikey=secret&file=The+Pending+Ebook",
      seeders: nil
    )

    logger = build_test_logger

    Rails.stub(:logger, logger) do
      VCR.turned_off do
        stub_request(:get, "http://localhost:8080/api")
          .with(query: hash_including(
            "mode" => "get_cats",
            "apikey" => "test-api-key-12345",
            "output" => "json"
          ))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "categories" => [ "*" ] }.to_json
          )

        request_stub = stub_request(:get, "http://localhost:8080/api")
          .with(query: hash_including(
            "mode" => "addurl",
            "name" => "http://prowlarr:9696/11/download?apikey=secret&file=The+Pending+Ebook",
            "nzbname" => "Another Author - The Pending Ebook",
            "apikey" => "test-api-key-12345",
            "output" => "json"
          ))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "status" => true, "nzo_ids" => [ "SABnzbd_nzo_12345" ] }.to_json
          )

        DownloadJob.perform_now(@download.id)

        assert_requested request_stub
      end
    end

    @download.reload
    assert @download.downloading?
    assert_equal sabnzbd.id.to_s, @download.download_client_id
    assert_equal "SABnzbd_nzo_12345", @download.external_id
    assert_equal "usenet", @download.download_type

    log_output = logger.messages.join("\n")
    assert_includes log_output, "apikey=[REDACTED]"
    assert_includes log_output, "file=The+Pending+Ebook"
    assert_not_includes log_output, "apikey=secret"
  end

  test "dispatches a manual NZB URL unchanged to the highest-priority healthy usenet client without logging secrets" do
    @client.destroy!
    high_priority = DownloadClient.create!(
      name: "High Priority SABnzbd",
      client_type: "sabnzbd",
      url: "http://sab-high.test:8080",
      api_key: "high-api-key",
      priority: 0,
      enabled: true
    )
    DownloadClient.create!(
      name: "Low Priority SABnzbd",
      client_type: "sabnzbd",
      url: "http://sab-low.test:8080",
      api_key: "low-api-key",
      priority: 10,
      enabled: true
    )
    signed_url = "https://alice:password@downloads.example/release/123?custom_secret=opaque&X-Amz-Signature=very-secret"
    manual_result = @request.search_results.create!(
      guid: "manual-nzb:#{Digest::SHA256.hexdigest(signed_url)}",
      title: "Manual NZB for #{@request.book.display_name}",
      indexer: "Manual NZB",
      source: SearchResult::SOURCE_MANUAL_NZB,
      download_url: signed_url,
      magnet_url: nil,
      seeders: nil,
      status: :selected
    )
    @download.update!(search_result: manual_result)
    logger = build_test_logger

    VCR.turned_off do
      high_connection = stub_request(:get, "http://sab-high.test:8080/api")
        .with(query: hash_including(
          "mode" => "get_cats",
          "apikey" => "high-api-key",
          "output" => "json"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "categories" => [ "*" ] }.to_json
        )
      low_connection = stub_request(:get, "http://sab-low.test:8080/api")
        .with(query: hash_including("mode" => "get_cats"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "categories" => [ "*" ] }.to_json
        )
      submission = stub_request(:get, "http://sab-high.test:8080/api")
        .with(query: hash_including(
          "mode" => "addurl",
          "name" => signed_url,
          "nzbname" => "Another Author - The Pending Ebook",
          "apikey" => "high-api-key",
          "output" => "json"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => true, "nzo_ids" => [ "SABnzbd_manual_123" ] }.to_json
        )

      Rails.stub(:logger, logger) do
        DownloadJob.perform_now(@download.id)
      end

      assert_requested high_connection, times: 1
      assert_not_requested low_connection
      assert_requested submission, times: 1
    end

    @download.reload
    assert @download.downloading?
    assert_equal high_priority.id.to_s, @download.download_client_id
    assert_equal "SABnzbd_manual_123", @download.external_id
    assert_equal "usenet", @download.download_type

    log_output = logger.messages.join("\n")
    assert_includes log_output, "[REDACTED MANUAL NZB URL]"
    assert_not_includes log_output, "alice"
    assert_not_includes log_output, "password"
    assert_not_includes log_output, "opaque"
    assert_not_includes log_output, "very-secret"
  end

  test "rejects manual NZB URLs targeting link-local services before client selection" do
    blocked_url = "http://169.254.169.254/latest/meta-data?token=very-secret"
    manual_result = @request.search_results.create!(
      guid: "manual-nzb:#{Digest::SHA256.hexdigest(blocked_url)}",
      title: "Manual NZB for #{@request.book.display_name}",
      indexer: "Manual NZB",
      source: SearchResult::SOURCE_MANUAL_NZB,
      download_url: blocked_url,
      magnet_url: nil,
      seeders: nil,
      status: :selected
    )
    @download.update!(search_result: manual_result)
    SettingsService.set(:auto_select_enabled, false)
    logger = build_test_logger

    Rails.stub(:logger, logger) do
      DownloadJob.perform_now(@download.id)
    end

    assert @download.reload.failed?
    assert manual_result.reload.blocklisted?
    assert_includes @request.reload.issue_description, "blocked or invalid destination"

    log_output = logger.messages.join("\n")
    assert_not_includes log_output, blocked_url
    assert_not_includes log_output, "very-secret"
  end

  test "rejects a manual replacement while a client dispatch is in flight" do
    @client.destroy!
    DownloadClient.create!(
      name: "Test SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key-12345",
      priority: 0,
      enabled: true
    )
    @selected_result.update!(
      magnet_url: nil,
      download_url: "https://indexer.example/old.nzb",
      seeders: nil,
      status: :selected
    )
    replacement_url = "https://downloads.example/replacement.nzb"
    replacement_error = nil

    VCR.turned_off do
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "get_cats"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "categories" => [ "*" ] }.to_json
        )
      submission = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "addurl", "name" => "https://indexer.example/old.nzb"))
        .to_return do
          replacement_error = assert_raises(ArgumentError) do
            @request.reload.add_manual_nzb!(replacement_url)
          end
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "status" => true, "nzo_ids" => [ "SABnzbd_nzo_current" ] }.to_json
          }
        end

      DownloadJob.perform_now(@download.id)

      assert_requested submission
    end

    assert_match(/dispatch is in progress/, replacement_error.message)
    assert_nil @request.reload.search_results.find_by(download_url: replacement_url)
    assert @selected_result.reload.selected?
    assert @download.reload.downloading?
    assert_equal "SABnzbd_nzo_current", @download.external_id
  end

  test "cleans up a custom client dispatch that loses ownership before finalization" do
    @download.update!(status: :downloading, download_type: "dispatching")
    removed_ids = []
    claimed_download = @download
    client = Object.new
    client.define_singleton_method(:add_torrent) do |_url|
      claimed_download.update!(status: :failed)
      "stale-torrent-hash"
    end
    client.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
      removed_ids << [ external_id, delete_files ]
      true
    end

    DownloadClientSelector.stub(:for_torrent, @client) do
      @client.stub(:adapter, client) do
        DownloadJob.new.send(
          :send_to_torrent_client,
          @download,
          @selected_result,
          "magnet:?xt=urn:btih:#{'c' * 40}"
        )
      end
    end

    assert @download.reload.failed?
    assert_nil @download.external_id
    assert_equal [ [ "stale-torrent-hash", true ] ], removed_ids
  end

  test "sends selected newznab result directly to a usenet client" do
    @client.destroy!
    sabnzbd = DownloadClient.create!(
      name: "Test SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key-12345",
      priority: 0,
      enabled: true
    )
    newznab_result = @request.search_results.create!(
      guid: "newznab-guid-123",
      title: "Newznab Ebook Result",
      indexer: "NZBHydra Books",
      source: SearchResult::SOURCE_NEWZNAB,
      download_url: "http://nzbhydra:5076/getnzb/api/123?apikey=secret",
      magnet_url: nil,
      seeders: nil,
      status: :selected
    )
    @download.update!(search_result: newznab_result)

    VCR.turned_off do
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including(
          "mode" => "get_cats",
          "apikey" => "test-api-key-12345",
          "output" => "json"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "categories" => [ "*" ] }.to_json
        )

      request_stub = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including(
          "mode" => "addurl",
          "name" => "http://nzbhydra:5076/getnzb/api/123?apikey=secret",
          "nzbname" => "Another Author - The Pending Ebook",
          "apikey" => "test-api-key-12345",
          "output" => "json"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => true, "nzo_ids" => [ "SABnzbd_nzo_newznab" ] }.to_json
        )

      DownloadJob.perform_now(@download.id)

      assert_requested request_stub
    end

    @download.reload
    assert @download.downloading?
    assert_equal sabnzbd.id.to_s, @download.download_client_id
    assert_equal "SABnzbd_nzo_newznab", @download.external_id
    assert_equal "usenet", @download.download_type
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

  test "infer_filename_from_url normalizes Gutenberg pseudo extensions" do
    job = DownloadJob.new

    assert_equal "1342.epub", job.send(:infer_filename_from_url, "https://www.gutenberg.org/ebooks/1342.epub3.images?download=1", @selected_result)
    assert_equal "2.mobi", job.send(:infer_filename_from_url, "https://www.gutenberg.org/ebooks/2.kf8.images", @selected_result)
    assert_equal "3.mobi", job.send(:infer_filename_from_url, "https://www.gutenberg.org/ebooks/3.kindle.noimages", @selected_result)
  end

  test "infer_filename_from_url ignores unsupported URL extensions without ebook hints" do
    job = DownloadJob.new
    filename = job.send(:infer_filename_from_url, "https://example.com/download/release.v1", @selected_result)

    assert_not_equal "release.epub", filename
    assert_includes filename, @selected_result.request.book.author
    assert_includes filename, @selected_result.request.book.title
  end

  test "z-library download completes via direct http download" do
    setup_zlibrary_download

    VCR.turned_off do
      ZLibraryClient.stub :get_download_url, "https://download.z-library.sk/books/test-book.epub" do
        stub_request(:get, "https://download.z-library.sk/books/test-book.epub")
          .to_return(status: 200, body: "PK\x03\x04" + ("x" * 1024), headers: { "Content-Type" => "application/epub+zip" })

        DownloadJob.perform_now(@zlibrary_download.id)
      end
    end

    @zlibrary_download.reload
    assert @zlibrary_download.completed?
    assert_equal "direct", @zlibrary_download.download_type
  end

  test "Project Gutenberg download completes via direct http download" do
    Dir.mktmpdir do |dir|
      setup_gutenberg_download(output_path: dir)

      VCR.turned_off do
        stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
          .with(query: hash_including("download" => "1"))
          .to_return(status: 200, body: "PK\x03\x04" + ("x" * 1024), headers: { "Content-Type" => "application/epub+zip" })

        DownloadJob.perform_now(@gutenberg_download.id)
      end

      @gutenberg_download.reload
      @gutenberg_request.reload
      assert @gutenberg_download.completed?
      assert_equal "direct", @gutenberg_download.download_type
      assert @gutenberg_request.completed?
      assert File.exist?(@gutenberg_download.download_path)
      assert_equal "1342.epub", File.basename(@gutenberg_download.download_path)
      assert_equal File.dirname(@gutenberg_download.download_path), @gutenberg_request.book.file_path
      assert_equal 0o640, File.stat(@gutenberg_download.download_path).mode & 0o777
    end
  end

  test "direct download preserves an existing destination with different bytes" do
    Dir.mktmpdir do |dir|
      setup_gutenberg_download(output_path: dir)
      destination = gutenberg_destination_path(dir)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, "existing-owner-bytes")

      VCR.turned_off do
        stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
          .with(query: hash_including("download" => "1"))
          .to_return(
            status: 200,
            body: "PK\x03\x04" + ("new" * 256),
            headers: { "Content-Type" => "application/epub+zip" }
          )

        DownloadJob.perform_now(@gutenberg_download.id)
      end

      assert_equal "existing-owner-bytes", File.binread(destination)
      assert @gutenberg_download.reload.failed?
      assert @gutenberg_request.reload.attention_needed?
      assert_not @gutenberg_download.search_result.reload.blocklisted?
      assert_nil @gutenberg_request.book.reload.file_path
      assert_empty Dir.glob("#{destination}.*")
    end
  end

  test "direct download retry reuses an exact complete publication without a suffix" do
    Dir.mktmpdir do |dir|
      setup_gutenberg_download(output_path: dir)
      destination = gutenberg_destination_path(dir)
      bytes = "PK\x03\x04" + ("same" * 256)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)

      VCR.turned_off do
        stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
          .with(query: hash_including("download" => "1"))
          .to_return(status: 200, body: bytes, headers: { "Content-Type" => "application/epub+zip" })

        DownloadJob.perform_now(@gutenberg_download.id)
      end

      assert @gutenberg_download.reload.completed?
      assert_equal destination, @gutenberg_download.download_path
      assert_equal File.dirname(destination), @gutenberg_request.book.reload.file_path
      assert_equal [ destination ], Dir.glob("#{destination}*")
      assert_equal bytes, File.binread(destination)
    end
  end

  test "an interrupted direct response never exposes partial bytes at the final path" do
    Dir.mktmpdir do |dir|
      setup_gutenberg_download(output_path: dir)
      destination = gutenberg_destination_path(dir)
      job = DownloadJob.new

      interrupted_download = lambda do |_result, _url, staged_file, **_options|
        staged_file.write("PK\x03\x04partial")
        staged_file.flush
        raise IOError, "simulated disk interruption"
      end

      job.stub(:download_file_via_http, interrupted_download) do
        job.perform(@gutenberg_download.id)
      end

      assert_not File.exist?(destination)
      assert @gutenberg_download.reload.failed?
      assert_nil @gutenberg_request.book.reload.file_path
      assert_empty Dir.glob(File.join(dir, ".shelfarr-staging", "direct-downloads", "**", "download-*"))
    end
  end

  test "direct download rejects a symbolic-link destination ancestor" do
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        setup_gutenberg_download(output_path: dir)
        destination = gutenberg_destination_path(dir)
        author_directory = Pathname(destination).dirname.dirname
        File.symlink(outside, author_directory)

        VCR.turned_off do
          stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
            .with(query: hash_including("download" => "1"))
            .to_return(
              status: 200,
              body: "PK\x03\x04" + ("x" * 1024),
              headers: { "Content-Type" => "application/epub+zip" }
            )

          DownloadJob.perform_now(@gutenberg_download.id)
        end

        assert @gutenberg_download.reload.failed?
        assert_empty Dir.children(outside)
        assert_nil @gutenberg_request.book.reload.file_path
      end
    end
  end

  test "direct download rejects a destination ancestor swapped before publication" do
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        setup_gutenberg_download(output_path: dir)
        destination = gutenberg_destination_path(dir)
        original_copy = FileCopyService.method(:cp_io_noreplace)
        swap_then_copy = lambda do |source, path, root: nil, heartbeat: nil|
          parent = File.dirname(path)
          File.rename(parent, "#{parent}.moved")
          File.symlink(outside, parent)
          original_copy.call(source, path, root: root, heartbeat: heartbeat)
        end

        VCR.turned_off do
          stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
            .with(query: hash_including("download" => "1"))
            .to_return(
              status: 200,
              body: "PK\x03\x04" + ("x" * 1024),
              headers: { "Content-Type" => "application/epub+zip" }
            )

          FileCopyService.stub(:cp_io_noreplace, swap_then_copy) do
            DownloadJob.perform_now(@gutenberg_download.id)
          end
        end

        assert @gutenberg_download.reload.failed?
        assert_empty Dir.children(outside)
        assert_nil @gutenberg_request.book.reload.file_path
      end
    end
  end

  test "direct download preserves a different Book acquisition winner" do
    Dir.mktmpdir do |dir|
      setup_gutenberg_download(output_path: dir)
      destination = gutenberg_destination_path(dir)
      winner_directory = File.dirname(destination)
      winner_file = File.join(winner_directory, "winner.epub")
      FileUtils.mkdir_p(winner_directory)
      File.binwrite(winner_file, "winner")
      @gutenberg_request.book.update!(file_path: winner_directory)

      VCR.turned_off do
        remote_download = stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
          .with(query: hash_including("download" => "1"))
          .to_return(
            status: 200,
            body: "PK\x03\x04" + ("x" * 1024),
            headers: { "Content-Type" => "application/epub+zip" }
          )

        DownloadJob.perform_now(@gutenberg_download.id)
        assert_not_requested remote_download
      end

      assert_equal winner_directory, @gutenberg_request.book.reload.file_path
      assert_equal "winner", File.binread(winner_file)
      assert_not File.exist?(destination)
      assert @gutenberg_download.reload.failed?
      assert_not @gutenberg_download.search_result.reload.blocklisted?
    end
  end

  test "custom provider download acquires direct URL and completes via HTTP" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .with do |request|
            body = JSON.parse(request.body)
            body["provider_result_id"] == "custom-epub-1"
          end
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "https://files.test/custom-book.epub" }.to_json
          )

        stub_request(:get, "https://files.test/custom-book.epub")
          .to_return(status: 200, body: "PK\x03\x04" + ("x" * 1024), headers: { "Content-Type" => "application/epub+zip" })

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      @custom_provider_request.reload
      assert @custom_provider_download.completed?
      assert_equal "direct", @custom_provider_download.download_type
      assert @custom_provider_request.completed?
      assert File.exist?(@custom_provider_download.download_path)
      assert_equal "custom-book.epub", File.basename(@custom_provider_download.download_path)
    end
  end

  test "custom provider direct audiobook file downloads into audiobook output path" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_audiobook_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .with do |request|
            body = JSON.parse(request.body)
            body["provider_result_id"] == "custom-audio-1"
          end
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "https://files.test/custom-audiobook.m4b" }.to_json
          )

        stub_request(:get, "https://files.test/custom-audiobook.m4b")
          .to_return(status: 200, body: valid_m4b_audio, headers: { "Content-Type" => "audio/mp4" })

        DownloadJob.perform_now(@custom_provider_audiobook_download.id)
      end

      @custom_provider_audiobook_download.reload
      @custom_provider_audiobook_request.reload
      assert @custom_provider_audiobook_download.completed?
      assert_equal "direct", @custom_provider_audiobook_download.download_type
      assert @custom_provider_audiobook_request.completed?
      assert File.exist?(@custom_provider_audiobook_download.download_path)
      assert_equal "custom-audiobook.m4b", File.basename(@custom_provider_audiobook_download.download_path)
      assert_equal File.dirname(@custom_provider_audiobook_download.download_path), @custom_provider_audiobook_request.book.file_path
    end
  end

  test "Anna's Archive audiobook archive downloads into audiobook output path" do
    Dir.mktmpdir do |dir|
      audio_data = valid_mp3_audio
      zip_body = build_zip_archive("chapter_01.mp3" => audio_data)
      setup_anna_archive_audiobook_download(output_path: dir, guid: Digest::MD5.hexdigest(zip_body))

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/anna-audiobook.zip" do
          stub_request(:get, "https://files.test/anna-audiobook.zip")
            .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      @anna_archive_audiobook_download.reload
      @anna_archive_audiobook_request.reload
      assert @anna_archive_audiobook_download.completed?
      assert_equal "direct", @anna_archive_audiobook_download.download_type
      assert @anna_archive_audiobook_request.completed?
      assert_equal @anna_archive_audiobook_request.book.file_path, @anna_archive_audiobook_download.download_path
      assert File.exist?(File.join(@anna_archive_audiobook_download.download_path, "chapter_01.mp3"))
    end
  end

  test "Anna's Archive ZIP cannot bypass archive extraction with an audio URL suffix" do
    Dir.mktmpdir do |dir|
      zip_body = build_zip_archive("chapter_01.mp3" => valid_mp3_audio)
      setup_anna_archive_audiobook_download(output_path: dir, guid: Digest::MD5.hexdigest(zip_body))

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/disguised.mp3" do
          stub_request(:get, "https://files.test/disguised.mp3")
            .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/octet-stream" })

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      assert @anna_archive_audiobook_download.reload.completed?
      assert File.exist?(File.join(@anna_archive_audiobook_download.download_path, "chapter_01.mp3"))
    end
  end

  test "Anna's Archive rejects non-audio archive entries before publication" do
    Dir.mktmpdir do |dir|
      zip_body = build_zip_archive(
        "chapter_01.mp3" => valid_mp3_audio,
        "payload.html" => "<script>malicious()</script>",
        "nested/payload.zip" => "PK\x03\x04nested"
      )
      setup_anna_archive_audiobook_download(output_path: dir, guid: Digest::MD5.hexdigest(zip_body))

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/anna-audiobook.zip" do
          stub_request(:get, "https://files.test/anna-audiobook.zip")
            .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "unsupported file type"
      assert_nil @anna_archive_audiobook_request.book.reload.file_path
    end
  end

  test "Anna's Archive rejects a direct archive that does not match its advertised MD5" do
    Dir.mktmpdir do |dir|
      zip_body = build_zip_archive("chapter_01.mp3" => valid_mp3_audio)
      setup_anna_archive_audiobook_download(output_path: dir, guid: "00000000000000000000000000000000")

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/substituted.zip" do
          stub_request(:get, "https://files.test/substituted.zip")
            .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      download = @anna_archive_audiobook_download.reload
      assert download.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "did not match the selected file"
      assert_nil download.direct_staging_path
      assert_nil @anna_archive_audiobook_request.book.reload.file_path
    end
  end

  test "Anna's Archive rejects insecure direct download URLs" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir)
      insecure_url = "http://files.test/anna-audiobook.zip"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, insecure_url do
          insecure_request = stub_request(:get, insecure_url)

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)

          assert_not_requested insecure_request
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "insecure download URL"
    end
  end

  test "Anna's Archive rejects audiobook archives with invalid audio files" do
    Dir.mktmpdir do |dir|
      zip_body = build_zip_archive("chapter.mp3" => "not-audio-data")
      setup_anna_archive_audiobook_download(output_path: dir, guid: Digest::MD5.hexdigest(zip_body))

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, "https://files.test/not-an-audiobook.zip" do
          stub_request(:get, "https://files.test/not-an-audiobook.zip")
            .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

          DownloadJob.perform_now(@anna_archive_audiobook_download.id)
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "does not contain valid supported audio files"
    end
  end

  test "Anna's Archive rejects audiobook torrents that would bypass archive validation" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir)
      magnet = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      AnnaArchiveClient.stub :get_download_url, magnet do
        DownloadJob.perform_now(@anna_archive_audiobook_download.id)
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "verified post-download archive processing"
      assert_nil @anna_archive_audiobook_request.book.reload.file_path
    end
  end

  test "Anna's Archive dispatches signed torrent URLs to the torrent client" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir, book_type: :ebook)
      torrent_url = "https://example.com/download/audiobook.torrent?token=secret"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, torrent_url do
          stub_qbittorrent_success(torrent_url: torrent_url)

          with_outbound_resolver(->(_host) { [ "203.0.113.10" ] }) do
            DownloadJob.perform_now(@anna_archive_audiobook_download.id)
          end
        end
      end

      assert @anna_archive_audiobook_download.reload.downloading?
      assert_equal "torrent", @anna_archive_audiobook_download.download_type
    end
  end

  test "Anna's Archive rejects torrent redirects to private addresses" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir, book_type: :ebook)
      torrent_url = "https://files.test/audiobook.torrent"
      private_url = "http://private.test/internal.torrent"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, torrent_url do
          stub_qbittorrent_connection("http://localhost:8080")
          stub_request(:get, torrent_url).to_return(status: 302, headers: { "Location" => private_url })
          private_request = stub_request(:get, private_url)
          resolver = ->(host) { host == "private.test" ? [ "10.0.0.5" ] : [ "203.0.113.10" ] }

          with_outbound_resolver(resolver) do
            DownloadJob.perform_now(@anna_archive_audiobook_download.id)
          end

          assert_not_requested private_request
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "Refused unsafe torrent source URL"
    end
  end

  test "Anna's Archive does not blocklist transient torrent source failures" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir, book_type: :ebook)
      torrent_url = "https://files.test/audiobook.torrent"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, torrent_url do
          stub_qbittorrent_connection("http://localhost:8080")
          stub_request(:get, torrent_url).to_return(status: 503, body: "Unavailable")

          with_outbound_resolver(->(_host) { [ "203.0.113.10" ] }) do
            DownloadJob.perform_now(@anna_archive_audiobook_download.id)
          end
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert @anna_archive_audiobook_request.reload.attention_needed?
      assert_not @anna_archive_audiobook_download.search_result.reload.blocklisted?
    end
  end

  test "Anna's Archive does not blocklist torrent source connection failures" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir, book_type: :ebook)
      torrent_url = "https://files.test/audiobook.torrent"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, torrent_url do
          stub_qbittorrent_connection("http://localhost:8080")
          stub_request(:get, torrent_url).to_raise(Errno::ECONNREFUSED.new)

          with_outbound_resolver(->(_host) { [ "203.0.113.10" ] }) do
            DownloadJob.perform_now(@anna_archive_audiobook_download.id)
          end
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert @anna_archive_audiobook_request.reload.attention_needed?
      assert_not @anna_archive_audiobook_download.search_result.reload.blocklisted?
    end
  end

  test "Anna's Archive rejects malformed torrent redirects through the download lifecycle" do
    Dir.mktmpdir do |dir|
      setup_anna_archive_audiobook_download(output_path: dir, book_type: :ebook)
      torrent_url = "https://files.test/audiobook.torrent"

      VCR.turned_off do
        AnnaArchiveClient.stub :get_download_url, torrent_url do
          stub_qbittorrent_connection("http://localhost:8080")
          stub_request(:get, torrent_url).to_return(status: 302, headers: { "Location" => "http://[" })

          with_outbound_resolver(->(_host) { [ "203.0.113.10" ] }) do
            DownloadJob.perform_now(@anna_archive_audiobook_download.id)
          end
        end
      end

      assert @anna_archive_audiobook_download.reload.failed?
      assert_includes @anna_archive_audiobook_request.reload.issue_description, "Invalid torrent source redirect"
    end
  end

  test "custom provider torrent acquisition dispatches magnet to torrent client" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)
      magnet = "magnet:?xt=urn:btih:#{"a" * 40}"

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "torrent", magnet_url: magnet }.to_json
          )
        stub_qbittorrent_connection("http://localhost:8080")
        stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
          .to_return(status: 200, body: "Ok.")
        stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: [ { "hash" => "a" * 40, "name" => "Custom Torrent", "progress" => 0, "state" => "downloading", "size" => 1000, "content_path" => "/downloads/Custom Torrent" } ].to_json
          )

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      assert @custom_provider_download.downloading?
      assert_equal "torrent", @custom_provider_download.download_type
      assert_equal "a" * 40, @custom_provider_download.external_id
    end
  end

  test "custom provider usenet acquisition dispatches NZB URL to usenet client" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)
      @client.destroy!
      DownloadClient.create!(
        name: "Test SABnzbd",
        client_type: "sabnzbd",
        url: "http://localhost:8080",
        api_key: "test-api-key-12345",
        priority: 0,
        enabled: true
      )

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "usenet", nzb_url: "https://files.test/custom-book.nzb" }.to_json
          )
        stub_request(:get, "http://localhost:8080/api")
          .with(query: hash_including("mode" => "get_cats"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "categories" => [ "*" ] }.to_json
          )
        stub_request(:get, "http://localhost:8080/api")
          .with(query: hash_including(
            "mode" => "addurl",
            "name" => "https://files.test/custom-book.nzb"
          ))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "status" => true, "nzo_ids" => [ "SABnzbd_nzo_67890" ] }.to_json
          )

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      assert @custom_provider_download.downloading?
      assert_equal "usenet", @custom_provider_download.download_type
      assert_equal "SABnzbd_nzo_67890", @custom_provider_download.external_id
    end
  end

  test "custom provider acquisition with unsupported artifact type fails with attention" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "ftp", direct_url: "ftp://files.test/book.epub" }.to_json
          )

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      @custom_provider_request.reload
      assert @custom_provider_download.failed?
      assert @custom_provider_request.attention_needed?
    end
  end

  test "custom provider direct download to a private address is blocked by default" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "http://192.168.1.5/book.epub" }.to_json
          )

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      @custom_provider_request.reload
      assert @custom_provider_download.failed?
      assert @custom_provider_request.attention_needed?
      assert_not_requested :get, "http://192.168.1.5/book.epub"
    end
  end

  test "custom provider direct download to a private address works when provider allows private network" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)
      @custom_provider_download.search_result.acquisition_provider.update!(allow_private_network: true)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "http://192.168.1.5/custom-book.epub" }.to_json
          )
        stub_request(:get, "http://192.168.1.5/custom-book.epub")
          .to_return(status: 200, body: "PK\x03\x04" + ("x" * 1024), headers: { "Content-Type" => "application/epub+zip" })

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      assert @custom_provider_download.completed?
    end
  end

  test "custom provider direct download never follows metadata addresses even with private network allowed" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)
      @custom_provider_download.search_result.acquisition_provider.update!(allow_private_network: true)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "http://169.254.169.254/latest/meta-data" }.to_json
          )

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      assert @custom_provider_download.failed?
      assert_not_requested :get, "http://169.254.169.254/latest/meta-data"
    end
  end

  test "direct download redirects to private addresses are blocked" do
    Dir.mktmpdir do |dir|
      setup_custom_provider_download(output_path: dir)

      VCR.turned_off do
        stub_request(:post, "http://provider.test/acquire")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { download_type: "direct", direct_url: "https://files.test/custom-book.epub" }.to_json
          )
        stub_request(:get, "https://files.test/custom-book.epub")
          .to_return(status: 302, headers: { "Location" => "http://10.0.0.5/internal-secret" })

        DownloadJob.perform_now(@custom_provider_download.id)
      end

      @custom_provider_download.reload
      assert @custom_provider_download.failed?
      assert_not_requested :get, "http://10.0.0.5/internal-secret"
    end
  end

  test "validate_direct_download_url rejects private addresses for non-custom sources" do
    error = assert_raises RuntimeError do
      DownloadJob.new.send(:validate_direct_download_url!, "http://127.0.0.1/book.epub")
    end

    assert_match(/Invalid direct download URL/, error.message)
  end

  test "infer_audiobook_extension requires format context for ambiguous words like opus" do
    job = DownloadJob.new
    result = Struct.new(:title)

    assert_nil job.send(:infer_audiobook_extension, "https://files.test/download", result.new("Live at the Opus House"))
    assert_equal "opus", job.send(:infer_audiobook_extension, "https://files.test/download", result.new("Book Title [OPUS]"))
    assert_equal "opus", job.send(:infer_audiobook_extension, "https://files.test/download", result.new("Book Title .opus"))
    assert_equal "mp3", job.send(:infer_audiobook_extension, "https://files.test/download", result.new("Book Title MP3 64kbps"))
  end

  test "rejects shallow ADIF AAC signatures as audiobook content" do
    Tempfile.create([ "audiobook", ".aac" ]) do |file|
      file.binmode
      file.write("ADIF" + SecureRandom.random_bytes(2.kilobytes))
      file.flush

      assert_not DownloadJob.new.send(:valid_audiobook_signature?, file.path)
    end
  end

  test "rejects audiobook archives with excessive audio file counts before probing" do
    Dir.mktmpdir do |directory|
      (DownloadJob::MAX_AUDIOBOOK_ARCHIVE_AUDIO_FILES + 1).times do |index|
        File.write(File.join(directory, "chapter-#{index}.mp3"), "")
      end

      error = assert_raises(RuntimeError) do
        DownloadJob.new.send(:verify_extracted_audiobook!, directory)
      end
      assert_includes error.message, "too many audio files"
    end
  end

  test "librivox download extracts audiobook zip into audiobook output path" do
    Dir.mktmpdir do |dir|
      setup_librivox_download(output_path: dir)
      audio_data = valid_mp3_audio
      zip_body = build_zip_archive("chapter_01.mp3" => audio_data)

      VCR.turned_off do
        stub_request(:get, "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3")
          .to_return(
            status: 302,
            headers: {
              "Location" => "https://ia801600.us.archive.org/zip_dir.php?path=/35/items/test_librivox.zip&formats=64KBPS MP3"
            }
          )
        stub_request(:get, "https://ia801600.us.archive.org/zip_dir.php?path=/35/items/test_librivox.zip&formats=64KBPS%20MP3")
          .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

        DownloadJob.perform_now(@librivox_download.id)
      end

      @librivox_download.reload
      @librivox_request.reload
      assert @librivox_download.completed?
      assert_equal "direct", @librivox_download.download_type
      assert @librivox_request.completed?
      assert_equal @librivox_request.book.file_path, @librivox_download.download_path
      chapter = File.join(@librivox_download.download_path, "chapter_01.mp3")
      assert File.exist?(chapter)
      assert_equal 0o640, File.stat(chapter).mode & 0o777
    end
  end

  test "librivox archive uses an atomic per-title directory when audiobook output is flat" do
    Dir.mktmpdir do |dir|
      original_template = SettingsService.get(:audiobook_path_template)
      SettingsService.set(:audiobook_path_template, "")
      setup_librivox_download(output_path: dir)
      audio_data = valid_mp3_audio
      zip_body = build_zip_archive("chapter_01.mp3" => audio_data)

      VCR.turned_off do
        stub_request(:get, "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3")
          .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

        DownloadJob.perform_now(@librivox_download.id)
      end

      destination = @librivox_download.reload.download_path
      assert @librivox_download.completed?
      assert_not_equal dir, destination
      assert_equal "Jane Austen - Test LibriVox Book", File.basename(destination)
      assert_equal audio_data, File.binread(File.join(destination, "chapter_01.mp3"))
    ensure
      SettingsService.set(:audiobook_path_template, original_template)
    end
  end

  test "librivox download rejects unsafe zip paths" do
    Dir.mktmpdir do |dir|
      setup_librivox_download(output_path: dir)
      zip_body = build_zip_archive("../escape.mp3" => "audio-data")

      VCR.turned_off do
        stub_request(:get, "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3")
          .to_return(status: 200, body: zip_body, headers: { "Content-Type" => "application/zip" })

        DownloadJob.perform_now(@librivox_download.id)
      end

      @librivox_download.reload
      @librivox_request.reload
      assert @librivox_download.failed?
      assert @librivox_request.attention_needed?
      assert_not File.exist?(File.join(dir, "escape.mp3"))
    end
  end

  test "archive extraction heartbeats while traversing many small entries" do
    require "zip"

    Dir.mktmpdir do |destination|
      Tempfile.create([ "heartbeat-archive-", ".zip" ]) do |archive|
        archive.close
        Zip::File.open(archive.path, create: true) do |zipfile|
          zipfile.mkdir("disc-one")
          zipfile.mkdir("disc-two")
          zipfile.get_output_stream("chapter.mp3") { |stream| stream.write("audio") }
        end

        job = DownloadJob.new
        heartbeat_count = 0
        tick = -11.0
        clock = ->(*) { tick += 11.0 }
        heartbeat = lambda do |_download|
          heartbeat_count += 1
        end

        Process.stub(:clock_gettime, clock) do
          job.stub(:refresh_direct_download_heartbeat!, heartbeat) do
            File.open(archive.path, "rb") do |source|
              job.send(
                :extract_zip_to_directory,
                source,
                destination,
                output_root: destination,
                download: @download
              )
            end
          end
        end

        assert_operator heartbeat_count, :>=, 2
        assert_equal "audio", File.binread(File.join(destination, "chapter.mp3"))
      end
    end
  end

  test "z-library download rejects html error pages" do
    setup_zlibrary_download

    VCR.turned_off do
      ZLibraryClient.stub :get_download_url, "https://download.z-library.sk/books/test-book.epub" do
        stub_request(:get, "https://download.z-library.sk/books/test-book.epub")
          .to_return(status: 200, body: "<html><body>error</body></html>", headers: { "Content-Type" => "text/html" })

        DownloadJob.perform_now(@zlibrary_download.id)
      end
    end

    @zlibrary_download.reload
    @request.reload
    assert @zlibrary_download.failed?
    assert @request.attention_needed?
  end

  test "validate_direct_download_url rejects non-http schemes" do
    error = assert_raises RuntimeError do
      DownloadJob.new.send(:validate_direct_download_url!, "file:///tmp/book.epub")
    end

    assert_match /Invalid direct download URL/, error.message
  end

  test "validate_direct_download_url allows z-library hosts outside configured family" do
    setup_zlibrary_download

    uri = DownloadJob.new.send(:validate_direct_download_url!, "https://evil.example/book.epub", @request.search_results.selected.first)
    assert_equal "evil.example", uri.host
  end

  test "validate_direct_download_response_headers rejects html content types" do
    error = assert_raises RuntimeError do
      DownloadJob.new.send(
        :validate_direct_download_response_headers!,
        content_type: "text/html; charset=utf-8",
        content_length: "1024"
      )
    end

    assert_match /unexpected content type/i, error.message
  end

  test "validate_direct_download_response_headers rejects oversized downloads" do
    error = assert_raises RuntimeError do
      DownloadJob.new.send(
        :validate_direct_download_response_headers!,
        content_type: "application/epub+zip",
        content_length: (DownloadJob::MAX_DIRECT_DOWNLOAD_BYTES + 1).to_s
      )
    end

    assert_match /size limit/i, error.message
  end

  test "verify_downloaded_ebook rejects invalid pdf signature" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.pdf")
      File.binwrite(path, "not a pdf")

      error = assert_raises RuntimeError do
        DownloadJob.new.send(:verify_downloaded_ebook!, path, expected_extension: "pdf")
      end

      assert_match /not a valid PDF/, error.message
    end
  end

  test "verify_downloaded_ebook rejects html and invalid epub and mobi files" do
    Dir.mktmpdir do |dir|
      html_path = File.join(dir, "book.epub")
      File.binwrite(html_path, "<!doctype html><html></html>")
      assert_raises(RuntimeError) { DownloadJob.new.send(:verify_downloaded_ebook!, html_path, expected_extension: "epub") }
      assert File.exist?(html_path), "validation must not unlink a path it does not own"

      epub_path = File.join(dir, "bad.epub")
      File.binwrite(epub_path, "not a zip")
      assert_raises(RuntimeError) { DownloadJob.new.send(:verify_downloaded_ebook!, epub_path, expected_extension: "epub") }

      mobi_path = File.join(dir, "bad.mobi")
      File.binwrite(mobi_path, "x" * 80)
      assert_raises(RuntimeError) { DownloadJob.new.send(:verify_downloaded_ebook!, mobi_path, expected_extension: "mobi") }
    end
  end

  test "verify_downloaded_ebook rejects missing and empty files" do
    Dir.mktmpdir do |dir|
      missing_path = File.join(dir, "missing.epub")
      assert_raises(RuntimeError) { DownloadJob.new.send(:verify_downloaded_ebook!, missing_path) }

      empty_path = File.join(dir, "empty.epub")
      File.write(empty_path, "")
      assert_raises(RuntimeError) { DownloadJob.new.send(:verify_downloaded_ebook!, empty_path) }
    end
  end

  test "send_to_torrent_client marks attention when client returns no hash" do
    @download.update!(status: :downloading, download_type: "dispatching")
    client = Object.new
    def client.add_torrent(_url)
      nil
    end

    DownloadClientSelector.stub(:for_torrent, @client) do
      @client.stub(:adapter, client) do
        DownloadJob.new.send(:send_to_torrent_client, @download, @selected_result, "magnet:?xt=urn:btih:test")
      end
    end

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
  end

  test "check_for_duplicate_external_id logs duplicates without raising" do
    existing = @request.downloads.create!(
      name: "Existing",
      status: :downloading,
      external_id: "same-hash"
    )

    assert_nothing_raised do
      DownloadJob.new.send(:check_for_duplicate_external_id, existing.external_id, @download.id)
    end
  end

  test "sends attention notification when no search result selected" do
    @request.search_results.update_all(status: :pending)
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      DownloadJob.perform_now(@download.id)
    end

    assert_equal [ @request ], attention_requests
  end

  test "sends attention notification when no download client is available" do
    DownloadClient.destroy_all
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      DownloadJob.perform_now(@download.id)
    end

    assert_equal [ @request ], attention_requests
  end

  test "sends attention notification when selected result has no download link" do
    @selected_result.update!(download_url: nil, magnet_url: nil, source: "prowlarr")
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      DownloadJob.perform_now(@download.id)
    end

    assert_equal [ @request ], attention_requests
  end

  test "build_usenet_job_name falls back to search result title when book metadata is blank" do
    book = Struct.new(:author, :title).new("", "")
    request = Struct.new(:book).new(book)
    search_result = Struct.new(:request, :title).new(request, "Indexer Result Title")

    result = DownloadJob.new.send(:build_usenet_job_name, search_result)

    assert_equal "Indexer Result Title", result
  end

  private

  def setup_zlibrary_download
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")
    SettingsService.set(:ebook_output_path, Dir.tmpdir)

    zlibrary_result = @request.search_results.create!(
      guid: "999:deadbeef",
      title: "Z-Library Result [EPUB]",
      indexer: "Z-Library",
      source: SearchResult::SOURCE_ZLIBRARY,
      status: :selected
    )
    @request.search_results.where.not(id: zlibrary_result.id).update_all(status: :rejected)

    @zlibrary_download = @request.downloads.create!(
      name: zlibrary_result.title,
      size_bytes: 1_000_000,
      status: :queued
    )
  end

  def setup_librivox_download(output_path:)
    SettingsService.set(:librivox_enabled, true)
    SettingsService.set(:audiobook_output_path, output_path)

    book = Book.create!(
      title: "Test LibriVox Book",
      author: "Jane Austen",
      book_type: :audiobook
    )
    @librivox_request = Request.create!(book: book, user: users(:one), status: :downloading)
    librivox_result = @librivox_request.search_results.create!(
      guid: "librivox:253",
      title: "Test LibriVox Book - Jane Austen [AUDIOBOOK ZIP] [English]",
      indexer: "LibriVox",
      source: SearchResult::SOURCE_LIBRIVOX,
      download_url: "https://archive.org/compress/test_librivox/formats=64KBPS%20MP3",
      status: :selected
    )
    @librivox_download = @librivox_request.downloads.create!(
      name: librivox_result.title,
      search_result: librivox_result,
      status: :queued
    )
  end

  def setup_anna_archive_audiobook_download(
    output_path:,
    guid: "11111111111111111111111111111111",
    book_type: :audiobook
  )
    SettingsService.set(book_type == :audiobook ? :audiobook_output_path : :ebook_output_path, output_path)

    book = Book.create!(
      title: "Anna's Archive Audiobook",
      author: "Audio Author",
      book_type: book_type
    )
    @anna_archive_audiobook_request = Request.create!(book: book, user: users(:one), status: :downloading)
    result = @anna_archive_audiobook_request.search_results.create!(
      guid: guid,
      title: "Anna's Archive Audiobook - Audio Author [#{book_type == :audiobook ? 'AUDIOBOOK ZIP' : 'EPUB'}]",
      indexer: "Anna's Archive",
      source: SearchResult::SOURCE_ANNA_ARCHIVE,
      status: :selected
    )
    @anna_archive_audiobook_download = @anna_archive_audiobook_request.downloads.create!(
      name: result.title,
      search_result: result,
      status: :queued
    )
  end

  def setup_gutenberg_download(output_path:)
    SettingsService.set(:gutenberg_enabled, true)
    SettingsService.set(:ebook_output_path, output_path)

    book = Book.create!(
      title: "Pride and Prejudice",
      author: "Austen, Jane",
      book_type: :ebook
    )
    @gutenberg_request = Request.create!(book: book, user: users(:one), status: :downloading)
    gutenberg_result = @gutenberg_request.search_results.create!(
      guid: "gutenberg:1342",
      title: "Pride and Prejudice - Austen, Jane [EPUB]",
      indexer: "Project Gutenberg",
      source: SearchResult::SOURCE_GUTENBERG,
      download_url: "https://www.gutenberg.org/ebooks/1342.epub3.images?download=1",
      status: :selected
    )
    @gutenberg_download = @gutenberg_request.downloads.create!(
      name: gutenberg_result.title,
      search_result: gutenberg_result,
      status: :queued
    )
  end

  def gutenberg_destination_path(output_path)
    File.join(
      PathTemplateService.build_destination(@gutenberg_request.book, base_path: output_path),
      "1342.epub"
    )
  end

  def setup_custom_provider_download(output_path:)
    SettingsService.set(:ebook_output_path, output_path)

    provider = AcquisitionProvider.create!(
      name: "Local Provider",
      url: "http://provider.test",
      supports_ebooks: true,
      supports_audiobooks: false
    )
    book = Book.create!(
      title: "Custom Provider Book",
      author: "Provider Author",
      book_type: :ebook
    )
    @custom_provider_request = Request.create!(book: book, user: users(:one), status: :downloading)
    custom_result = @custom_provider_request.search_results.create!(
      guid: "custom:#{provider.id}:custom-epub-1",
      title: "Custom Provider Book - Provider Author [EPUB]",
      indexer: provider.name,
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: provider,
      provider_result_id: "custom-epub-1",
      provider_payload: { "download_type" => "direct", "format" => "epub" },
      status: :selected
    )
    @custom_provider_download = @custom_provider_request.downloads.create!(
      name: custom_result.title,
      search_result: custom_result,
      status: :queued
    )
  end

  def setup_custom_provider_audiobook_download(output_path:)
    SettingsService.set(:audiobook_output_path, output_path)

    provider = AcquisitionProvider.create!(
      name: "Local Audio Provider",
      url: "http://provider.test",
      supports_ebooks: false,
      supports_audiobooks: true
    )
    book = Book.create!(
      title: "Custom Provider Audiobook",
      author: "Provider Narrator",
      book_type: :audiobook
    )
    @custom_provider_audiobook_request = Request.create!(book: book, user: users(:one), status: :downloading)
    custom_result = @custom_provider_audiobook_request.search_results.create!(
      guid: "custom:#{provider.id}:custom-audio-1",
      title: "Custom Provider Audiobook - Provider Narrator [M4B]",
      indexer: provider.name,
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: provider,
      provider_result_id: "custom-audio-1",
      provider_payload: { "download_type" => "direct", "format" => "m4b" },
      status: :selected
    )
    @custom_provider_audiobook_download = @custom_provider_audiobook_request.downloads.create!(
      name: custom_result.title,
      search_result: custom_result,
      status: :queued
    )
  end

  def build_zip_archive(entries)
    require "zip"

    Tempfile.create([ "shelfarr-test-", ".zip" ]) do |file|
      file.close
      Zip::File.open(file.path, create: true) do |zipfile|
        entries.each do |name, content|
          zipfile.get_output_stream(name) { |stream| stream.write(content) }
        end
      end
      File.binread(file.path)
    end
  end

  def valid_mp3_audio
    id3_header = "ID3\x04\x00\x00\x00\x00\x00\x00".b
    mpeg_frame_header = "\xFF\xFB\x90\x64".b
    frames = 3.times.map { mpeg_frame_header + SecureRandom.random_bytes(413) }.join
    id3_header + frames
  end

  def valid_m4b_audio
    ftyp = [ 24 ].pack("N") + "ftyp" + "M4B \x00\x00\x00\x00M4B mp42".b
    payload = SecureRandom.random_bytes(2.kilobytes)
    ftyp + [ payload.bytesize + 8 ].pack("N") + "mdat" + payload
  end

  def stub_qbittorrent_success(torrent_url: "http://example.com/download/test.torrent")
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
    stub_request(:get, torrent_url)
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
        body: [ { "hash" => expected_hash, "name" => "Test Torrent", "progress" => 0, "state" => "downloading", "size" => 1000, "content_path" => "/downloads/Test Torrent" } ].to_json
      )
  end

  def with_outbound_resolver(resolver)
    previous = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = resolver
    yield
  ensure
    OutboundUrlGuard.resolver = previous
  end

  def build_test_logger
    Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def debug(message)
        @messages << message
      end

      def info(message)
        @messages << message
      end

      def warn(message)
        @messages << message
      end

      def error(message)
        @messages << message
      end
    end.new
  end
end
