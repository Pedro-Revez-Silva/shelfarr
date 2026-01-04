# frozen_string_literal: true

require "test_helper"

class DownloadMonitorJobTest < ActiveJob::TestCase
  setup do
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

  test "marks download as failed when removed from client" do
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
