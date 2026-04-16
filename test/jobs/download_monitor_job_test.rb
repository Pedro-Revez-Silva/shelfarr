# frozen_string_literal: true

require "test_helper"

class DownloadMonitorJobTest < ActiveJob::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    DownloadMonitorJob.clear_schedule!
    DownloadClient.destroy_all
    @request = requests(:pending_request)

    # Create a qBittorrent client
    @qbittorrent = DownloadClient.create!(
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
    Thread.current[:transmission_sessions] = {}
    Thread.current[:transmission_protocols] = {}

    # Create an active download associated with the client
    @download = @request.downloads.create!(
      name: "Test Audiobook",
      size_bytes: 1073741824,
      status: :downloading,
      external_id: "abc123def456",
      download_type: "torrent",
      progress: 50,
      download_client: @qbittorrent
    )
  end

  teardown do
    DownloadMonitorJob.clear_schedule!
    Rails.cache = @original_cache
  end

  test "does nothing when no download client configured" do
    DownloadClient.destroy_all

    assert_no_enqueued_jobs do
      DownloadMonitorJob.perform_now
    end
  end

  test "schedules next run after monitoring" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 75, state: "downloading")

      assert_enqueued_with(job: DownloadMonitorJob) do
        DownloadMonitorJob.perform_now
      end
    end
  end

  test "updates download progress" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 75, state: "downloading")

      DownloadMonitorJob.perform_now
      @download.reload

      assert_equal 75, @download.progress
    end
  end

  test "handles completed download and triggers post-processing" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 100, state: "uploading")

      assert_enqueued_with(job: PostProcessingJob, args: [@download.id]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal 100, @download.progress
    end
  end

  test "handles qBittorrent v5 stoppedUP state as completed and triggers post-processing" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 100, state: "stoppedUP")

      assert_enqueued_with(job: PostProcessingJob, args: [@download.id]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal 100, @download.progress
    end
  end

  test "does not immediately fail download on first not-found" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_not_found

      DownloadMonitorJob.perform_now
      @download.reload

      assert @download.downloading?
      assert_equal 1, @download.not_found_count
    end
  end

  test "marks download as failed after not-found threshold exceeded" do
    @download.update!(not_found_count: DownloadMonitorJob::NOT_FOUND_THRESHOLD - 1)

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_not_found

      DownloadMonitorJob.perform_now
      @download.reload
      @request.reload

      assert @download.failed?
      assert @request.attention_needed?
      assert_includes @request.issue_description, "not found in client"
    end
  end

  test "resets not_found_count when download is found again" do
    @download.update!(not_found_count: 2)

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 75, state: "downloading")

      DownloadMonitorJob.perform_now
      @download.reload

      assert_equal 0, @download.not_found_count
      assert @download.downloading?
    end
  end

  test "marks download as failed when client reports error" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 0, state: "error")

      DownloadMonitorJob.perform_now
      @download.reload
      @request.reload

      assert @download.failed?
      assert @request.attention_needed?
      assert_includes @request.issue_description, "failed in client"
    end
  end

  test "marks transmission download as failed when client reports local error" do
    transmission = DownloadClient.create!(
      name: "Test Transmission",
      client_type: "transmission",
      url: "http://localhost:9091",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @download.update!(
      external_id: "transmission-hash",
      download_client: transmission
    )

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
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          body = JSON.parse(request.body)
          body["jsonrpc"] == "2.0" &&
            body["method"] == "torrent_get" &&
            body["params"] == {
              "ids" => [ "transmission-hash" ],
              "fields" => DownloadClients::Transmission::TORRENT_FIELDS
            } &&
            body["id"] == 1
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "hash_string" => "transmission-hash",
                  "name" => "Test Audiobook",
                  "percent_done" => 0.0,
                  "status" => 4,
                  "error" => 3,
                  "error_string" => "Permission denied",
                  "total_size" => 1073741824,
                  "download_dir" => "/downloads/complete/Test Audiobook"
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      DownloadMonitorJob.perform_now
      @download.reload
      @request.reload

      assert @download.failed?
      assert @request.attention_needed?
      assert_includes @request.issue_description, "failed in client"
    end
  end

  test "uses SABnzbd for usenet downloads" do
    # Create SABnzbd client
    sabnzbd = DownloadClient.create!(
      name: "Test SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key",
      priority: 0,
      enabled: true
    )

    @download.update!(
      download_type: "usenet",
      external_id: "SABnzbd_nzo_12345",
      download_client: sabnzbd
    )

    VCR.turned_off do
      stub_sabnzbd_queue_with_item

      DownloadMonitorJob.perform_now
      @download.reload

      assert_equal 75, @download.progress
    end
  end

  test "handles completed SABnzbd download from history" do
    sabnzbd = DownloadClient.create!(
      name: "History SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key",
      priority: 0,
      enabled: true
    )

    @download.update!(
      download_type: "usenet",
      external_id: "SABnzbd_nzo_history_123",
      download_client: sabnzbd,
      progress: 0
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:8080/api.*mode=queue})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "queue" => { "slots" => [] } }.to_json
        )

      stub_request(:get, %r{localhost:8080/api.*mode=history})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "history" => {
              "slots" => [
                {
                  "nzo_id" => "SABnzbd_nzo_history_123",
                  "name" => "Completed Download",
                  "status" => "Completed",
                  "bytes" => 1024,
                  "storage" => "/downloads/complete/Completed Download"
                }
              ]
            }
          }.to_json
        )

      assert_enqueued_with(job: PostProcessingJob, args: [@download.id]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal 100, @download.progress
      assert_equal "/downloads/complete/Completed Download", @download.download_path
    end
  end

  test "ensure_running! only enqueues one monitor job while scheduled" do
    SettingsService.set(:download_check_interval, 60)

    assert_enqueued_with(job: DownloadMonitorJob) do
      DownloadMonitorJob.ensure_running!
    end

    assert_no_enqueued_jobs do
      DownloadMonitorJob.ensure_running!
    end
  end

  test "skips downloads without external_id" do
    @download.update!(external_id: nil)

    VCR.turned_off do
      stub_qbittorrent_auth

      # Should not make any torrent info requests
      DownloadMonitorJob.perform_now
      @download.reload

      # Status should remain unchanged
      assert @download.downloading?
      assert_equal 50, @download.progress
    end
  end

  test "flags queued downloads that never reached a client" do
    @download.update_columns(
      status: Download.statuses[:queued],
      external_id: nil,
      download_client_id: nil,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    )

    SettingsService.set(:download_enqueue_timeout_minutes, 5)

    assert_enqueued_with(job: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now
    end

    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "never sent to the download client"
  end

  test "skips downloads with disabled client" do
    @qbittorrent.update!(enabled: false)

    VCR.turned_off do
      DownloadMonitorJob.perform_now
      @download.reload

      # Status should remain unchanged
      assert @download.downloading?
      assert_equal 50, @download.progress
    end
  end

  test "sends attention notification when download fails in client" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 0, state: "error")
      attention_requests = []

      NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
        DownloadMonitorJob.perform_now
      end

      assert_equal [ @request ], attention_requests
    end
  end

  test "sends attention notification when download is missing after threshold" do
    @download.update!(not_found_count: DownloadMonitorJob::NOT_FOUND_THRESHOLD - 1)

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_not_found
      attention_requests = []

      NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
        DownloadMonitorJob.perform_now
      end

      assert_equal [ @request ], attention_requests
    end
  end

  test "sends attention notification when download stays queued past timeout" do
    @download.update_columns(
      status: Download.statuses[:queued],
      external_id: nil,
      download_client_id: nil,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    )
    SettingsService.set(:download_enqueue_timeout_minutes, 5)
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      DownloadMonitorJob.perform_now
    end

    assert_equal [ @request ], attention_requests
  end

  private

  def stub_qbittorrent_auth
    stub_request(:post, "http://localhost:8080/api/v2/auth/login")
      .to_return(
        status: 200,
        headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
        body: "Ok."
      )
  end

  def stub_qbittorrent_torrent_info(progress:, state:)
    stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [
          {
            "hash" => "abc123def456",
            "name" => "Test Audiobook",
            "progress" => progress / 100.0,
            "state" => state,
            "size" => 1073741824,
            "content_path" => "/downloads/complete/Test Audiobook"
          }
        ].to_json
      )
  end

  def stub_qbittorrent_torrent_not_found
    stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [].to_json
      )
  end

  def stub_sabnzbd_queue_with_item
    stub_request(:get, %r{localhost:8080/api.*mode=queue})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "queue" => {
            "slots" => [
              {
                "nzo_id" => "SABnzbd_nzo_12345",
                "filename" => "Test Audiobook",
                "percentage" => 75,
                "status" => "Downloading",
                "mb" => "1024",
                "storage" => "/downloads/incomplete"
              }
            ]
          }
        }.to_json
      )
  end
end
