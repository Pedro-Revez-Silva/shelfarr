# frozen_string_literal: true

require "test_helper"

class DownloadMonitorJobTest < ActiveJob::TestCase
  CLIENT_THREAD_LOCALS = %i[qbittorrent_sessions deluge_sessions transmission_sessions transmission_protocols].freeze

  def run
    Request.suppressing_turbo_broadcasts { super }
  end

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    DownloadMonitorJob.clear_schedule!
    DownloadClient.destroy_all
    @request = requests(:pending_request)

    @qbittorrent = DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )

    @original_client_thread_locals = CLIENT_THREAD_LOCALS.to_h do |key|
      [ key, Thread.current.key?(key) ? Thread.current[key] : :unset ]
    end
    CLIENT_THREAD_LOCALS.each { |key| Thread.current[key] = {} }

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
    @original_client_thread_locals&.each do |key, value|
      value == :unset ? Thread.current[key] = nil : Thread.current[key] = value
    end
  end

  test "does not reschedule when monitoring is not required" do
    DownloadClient.destroy_all
    clear_enqueued_jobs

    assert_not DownloadMonitorJob.monitoring_required?

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now
    end
  end

  test "does not enqueue another monitor after checking" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 75, state: "downloading")

      assert_no_enqueued_jobs(only: DownloadMonitorJob) do
        DownloadMonitorJob.perform_now
      end
      assert_equal 75, @download.reload.progress
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

  test "loads shared download clients once per polling batch" do
    9.times do |index|
      @request.downloads.create!(
        name: "Additional download #{index}", status: :downloading, progress: 50,
        external_id: "additional#{index}", download_type: "torrent", download_client: @qbittorrent
      )
    end
    client_reads = []
    capture = lambda do |_name, _start, _finish, _id, payload|
      client_reads << payload[:sql] if payload[:sql].match?(/\ASELECT .*FROM "download_clients"/)
    end

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 75, state: "downloading")
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
          DownloadMonitorJob.new.send(:monitor_active_downloads)
        end
      end
    end

    assert_equal [ 75 ], @request.downloads.pluck(:progress).uniq
    assert_equal 1, client_reads.size
  end

  test "does not start another monitor while one is claimed by a worker" do
    with_solid_queue_monitor_jobs do |monitor_jobs|
      job = DownloadMonitorJob.perform_later
      worker = SolidQueue::Process.register(kind: "Worker", name: "monitor-test", pid: Process.pid)
      claimed = SolidQueue::ReadyExecution.where(job_id: job.provider_job_id).claim([ "*" ], 1, worker.id).first
      assert_equal job.job_id, claimed&.job&.active_job_id

      assert_no_difference -> { monitor_jobs.count } do
        DownloadMonitorJob.ensure_running!
      end
    ensure
      worker&.destroy!
    end
  end

  test "recurring clock checks the download monitor without a command chain" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    assert_nil config.fetch("production")["download_monitor_recovery"]
    monitor = config.fetch("production").fetch("download_monitor")
    assert_equal "DownloadMonitorJob", monitor.fetch("class")
    assert_equal "every minute", monitor.fetch("schedule")
    assert_equal [ { "scheduled" => true } ], monitor.fetch("args")
    assert_nil monitor["command"]
    task = SolidQueue::RecurringTask.from_configuration("download_monitor", **monitor.symbolize_keys)
    assert task.valid?, task.errors.full_messages.join(", ")

    SettingsService.set(:download_check_interval, 60)
    Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, Time.current)

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now(scheduled: true)
    end
    assert_equal 50, @download.reload.progress
  end

  test "handles completed download and triggers post-processing" do
    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 100, state: "uploading")

      assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
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

      assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal 100, @download.progress
    end
  end

  test "handles Deluge torrents paused or stopped at 100% as completed and triggers post-processing" do
    deluge = DownloadClient.create!(
      name: "Monitor Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @download.update!(download_client: deluge)

    %w[Paused Stopped].each do |state|
      @download.update!(status: :downloading, progress: 50, download_path: nil)

      VCR.turned_off do
        Thread.current[:deluge_sessions] = {}
        stub_deluge_login
        stub_deluge_torrent_info(progress: 100, state: state)

        assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
          DownloadMonitorJob.perform_now
        end
      end

      @download.reload
      assert @download.completed?, "Deluge #{state} at 100% should complete the download"
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

  test "does not post-process incomplete paused Deluge torrents rounded to 100 percent" do
    deluge = DownloadClient.create!(
      name: "Incomplete Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @download.update!(download_client: deluge)

    %w[Paused PausedDownload PausedUpload Stopped].each do |state|
      [ 1.0, 99.5, 99.99 ].each do |progress|
        @download.update!(status: :downloading, progress: 0, download_path: nil)

        VCR.turned_off do
          Thread.current[:deluge_sessions] = {}
          stub_deluge_login
          stub_deluge_torrent_info(progress: progress, state: state)

          assert_no_enqueued_jobs(only: PostProcessingJob) do
            DownloadMonitorJob.perform_now
          end
        end

        assert @download.reload.downloading?, "Deluge #{state} at #{progress}% is incomplete"
        assert_equal progress.round, @download.progress
      end
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

  test "missing download after threshold blocklists release and selects next candidate" do
    SettingsService.set(:auto_select_enabled, true)
    SettingsService.set(:auto_select_confidence_threshold, 50)
    SettingsService.set(:auto_select_min_seeders, 1)
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    selected = search_results(:selected_result)
    fallback = search_results(:pending_result)
    fallback.update!(confidence_score: 95, detected_language: "en")
    @download.update!(
      search_result: selected,
      not_found_count: DownloadMonitorJob::NOT_FOUND_THRESHOLD - 1
    )

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_not_found

      assert_enqueued_with(job: DownloadJob) do
        DownloadMonitorJob.perform_now
      end
    end

    assert @download.reload.failed?
    assert selected.reload.blocklisted?
    assert fallback.reload.selected?
    assert @request.reload.downloading?
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

  test "client-reported failure blocklists release and selects next candidate" do
    SettingsService.set(:auto_select_enabled, true)
    SettingsService.set(:auto_select_confidence_threshold, 50)
    SettingsService.set(:auto_select_min_seeders, 1)
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    selected = search_results(:selected_result)
    fallback = search_results(:pending_result)
    fallback.update!(confidence_score: 95, detected_language: "en")
    @download.update!(search_result: selected)

    VCR.turned_off do
      stub_qbittorrent_auth
      stub_qbittorrent_torrent_info(progress: 0, state: "error")

      assert_enqueued_with(job: DownloadJob) do
        DownloadMonitorJob.perform_now
      end
    end

    assert @download.reload.failed?
    assert selected.reload.blocklisted?
    assert fallback.reload.selected?
    assert @request.reload.downloading?
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
              "fields" => DownloadClients::Transmission::JSONRPC_TORRENT_FIELDS
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

  test "completes a stopped Transmission torrent at 100 percent and enqueues post-processing" do
    transmission = DownloadClient.create!(
      name: "Stopped Transmission",
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

    # 0 is stopped after a seed or idle limit of 0. 5 is queued to seed.
    [ 0, 5 ].each do |status|
      @download.update!(status: :downloading, progress: 50, download_path: nil)
      Thread.current[:transmission_sessions] = {}
      Thread.current[:transmission_protocols] = {}

      VCR.turned_off do
        stub_transmission_monitor_torrent(percent_done: 1.0, status: status, left_until_done: 0)

        assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
          DownloadMonitorJob.perform_now
        end
      end

      @download.reload
      assert @download.completed?, "Transmission status #{status} at percentDone 1.0 should complete the download"
      assert_equal 100, @download.progress
      assert_equal "/downloads/complete/Test Audiobook", @download.download_path
    end
  end

  test "does not complete a stopped Transmission torrent that is still short of 100 percent" do
    transmission = DownloadClient.create!(
      name: "Incomplete Transmission",
      client_type: "transmission",
      url: "http://localhost:9091",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @download.update!(
      external_id: "transmission-hash",
      download_client: transmission,
      progress: 50
    )

    VCR.turned_off do
      stub_transmission_monitor_torrent(percent_done: 0.995, status: 0, left_until_done: 1024)

      assert_no_enqueued_jobs(only: PostProcessingJob) do
        DownloadMonitorJob.perform_now
      end
    end

    @download.reload
    assert @download.downloading?
    # 0.995 rounds to a displayed 100 and must still stay in progress.
    assert_equal 100, @download.progress
  end

  test "uses SABnzbd for usenet downloads" do
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

      assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal 100, @download.progress
      assert_equal "/downloads/complete/Completed Download", @download.download_path
    end
  end

  test "stores a SABnzbd history storage path that points at a completed file" do
    sabnzbd = DownloadClient.create!(
      name: "File History SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key",
      priority: 0,
      enabled: true
    )
    storage_file = "/Data/Downloads/Usenet/Books/Cassandra Clare - City of Ashes/" \
      "Cassandra Clare - City of Ashes (retail) (epub).epub"

    @download.update!(
      download_type: "usenet",
      external_id: "SABnzbd_nzo_history_file",
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
                  "nzo_id" => "SABnzbd_nzo_history_file",
                  "name" => "Cassandra Clare - City of Ashes",
                  "status" => "Completed",
                  "bytes" => 2048,
                  "storage" => storage_file
                }
              ]
            }
          }.to_json
        )

      assert_enqueued_with(job: PostProcessingJob, args: [ @download.id ]) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.completed?
      assert_equal storage_file, @download.download_path
    end
  end

  test "does not complete a SABnzbd download still in history post-processing" do
    sabnzbd = DownloadClient.create!(
      name: "Post-processing SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key",
      priority: 0,
      enabled: true
    )

    @download.update!(
      download_type: "usenet",
      external_id: "SABnzbd_nzo_extracting",
      download_client: sabnzbd,
      progress: 100,
      download_path: nil
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
                  "nzo_id" => "SABnzbd_nzo_extracting",
                  "name" => "Unpacking Download",
                  "status" => "Extracting",
                  "bytes" => 1024,
                  "storage" => ""
                }
              ]
            }
          }.to_json
        )

      assert_no_enqueued_jobs(only: PostProcessingJob) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.downloading?
      assert_not @download.completed?
      assert @download.download_path.blank?
    end
  end

  test "does not complete a SABnzbd history item whose storage path is still blank" do
    sabnzbd = DownloadClient.create!(
      name: "Blank-path SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-api-key",
      priority: 0,
      enabled: true
    )

    @download.update!(
      download_type: "usenet",
      external_id: "SABnzbd_nzo_blank_storage",
      download_client: sabnzbd,
      progress: 100
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
                  "nzo_id" => "SABnzbd_nzo_blank_storage",
                  "name" => "Completed-looking Download",
                  "status" => "Completed",
                  "bytes" => 1024,
                  "storage" => ""
                }
              ]
            }
          }.to_json
        )

      assert_no_enqueued_jobs(only: PostProcessingJob) do
        DownloadMonitorJob.perform_now
      end

      @download.reload
      assert @download.downloading?
      assert @download.download_path.blank?
    end
  end

  test "ensure_running! does not enqueue a monitor chain" do
    SettingsService.set(:download_check_interval, 60)

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.ensure_running!
      DownloadMonitorJob.ensure_running!
    end
  end

  test "ensure_running! does not enqueue when a protected monitor job is pending" do
    Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, 1.minute.ago.to_i)

    DownloadMonitorJob.stub(:monitor_job_pending?, true) do
      assert_no_enqueued_jobs(only: DownloadMonitorJob) do
        DownloadMonitorJob.ensure_running!
      end
    end
  end

  test "ensure_running! does not enqueue when the clock reservation is in the future" do
    Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, 1.hour.from_now.to_i)

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.ensure_running!
    end
  end

  test "consecutive minute ticks still monitor when a scan runs past its start" do
    SettingsService.set(:download_check_interval, 60)
    DownloadMonitorJob.clear_schedule!
    scanned_at = []
    start = Time.zone.parse("2026-08-26 12:00:00")
    job = DownloadMonitorJob.new

    job.stub(:monitor_active_downloads, -> {
      scanned_at << Time.current
      travel 3.seconds
    }) do
      travel_to start do
        job.perform(scheduled: true)
      end
    end

    assert_equal [ start ], scanned_at

    travel_to start + 1.minute do
      job.stub(:monitor_active_downloads, -> { scanned_at << Time.current }) do
        job.perform(scheduled: true)
      end
    end

    assert_equal start + 1.minute, scanned_at.last
  end

  test "a scheduled run before the interval elapses does not monitor or enqueue" do
    SettingsService.set(:download_check_interval, 60)
    Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, Time.current)

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now(scheduled: true)
    end
    assert_equal 50, @download.reload.progress
  end

  test "stale monitor instances claim a completed download only once" do
    first = Download.find(@download.id)
    stale = Download.find(@download.id)
    first_info = Struct.new(:download_path).new("/downloads/complete/Test Audiobook")
    stale_info = Struct.new(:download_path).new("/downloads/complete/Stale Path")
    clear_enqueued_jobs

    DownloadMonitorJob.new.send(:handle_completed, first, first_info)
    DownloadMonitorJob.new.send(:handle_completed, stale, stale_info)

    completed_events = @request.request_events.where(event_type: "completed", download_id: @download.id)
    post_processing_jobs = enqueued_jobs.select { |job| job[:job] == PostProcessingJob }

    assert_equal 1, completed_events.count
    assert_equal 1, post_processing_jobs.count
    assert_equal [ @download.id ], post_processing_jobs.first[:args]
    assert @download.reload.completed?
    assert_equal 100, @download.progress
    assert_equal first_info.download_path, @download.download_path
  end

  test "legacy argument-less monitors cannot bypass the interval gate" do
    scans = 0
    original = DownloadMonitorJob.instance_method(:monitor_active_downloads)
    DownloadMonitorJob.define_method(:monitor_active_downloads) { scans += 1 }
    DownloadMonitorJob.send(:private, :monitor_active_downloads)
    worker = nil

    with_solid_queue_monitor_jobs do
      legacy = DownloadMonitorJob.perform_later
      Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, 30.seconds.from_now.to_i)
      DownloadMonitorJob.ensure_running!
      worker = SolidQueue::Process.register(
        kind: "Worker",
        name: "legacy-monitor-#{SecureRandom.hex(4)}",
        pid: Process.pid,
        hostname: "test",
        metadata: {}
      )
      SolidQueue::ReadyExecution.where(job_id: legacy.provider_job_id).claim([ "*" ], 1, worker.id).each(&:perform)
      DownloadMonitorJob.perform_now(scheduled: true)
    end

    assert_equal 0, scans
  ensure
    worker&.destroy!
    if original
      DownloadMonitorJob.define_method(:monitor_active_downloads, original)
      DownloadMonitorJob.send(:private, :monitor_active_downloads)
    end
  end

  test "ensure_running! does not duplicate a persisted solid queue monitor" do
    with_solid_queue_monitor_jobs do |monitor_jobs|
      DownloadMonitorJob.set(wait: 1.minute).perform_later(scheduled: true)
      Rails.cache.write(DownloadMonitorJob::SCHEDULE_CACHE_KEY, 1.minute.ago.to_i)

      assert_equal 1, monitor_jobs.count
      assert_no_difference -> { monitor_jobs.count } do
        DownloadMonitorJob.ensure_running!
      end
    end
  end

  test "a due scheduled run watches a queued direct download without enqueueing a chain" do
    DownloadClient.destroy_all
    direct_result = search_results(:selected_result)
    direct_result.update!(source: SearchResult::SOURCE_GUTENBERG)
    @download.update!(
      status: :queued,
      external_id: nil,
      download_client: nil,
      download_type: nil,
      search_result: direct_result
    )
    DownloadMonitorJob.clear_schedule!

    assert DownloadMonitorJob.monitoring_required?
    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now(scheduled: true)
    end
    assert @download.reload.queued?
  end

  test "limits monitor execution to one protected job" do
    assert_equal DownloadMonitorJob::CONCURRENCY_KEY, DownloadMonitorJob.concurrency_key
    assert_equal 1, DownloadMonitorJob.concurrency_limit
    assert_equal 30.minutes, DownloadMonitorJob.concurrency_duration
    assert_equal :block, DownloadMonitorJob.concurrency_on_conflict
  end

  test "a claimed monitor lease survives concurrency maintenance past 30 minutes" do
    SolidQueue::Record.establish_connection(:queue)
    key = DownloadMonitorJob.new.concurrency_key
    assert_includes AudiobookshelfLibrarySyncJob::ConcurrencyLease::KEYS, key

    process = SolidQueue::Process.register(
      kind: "Worker",
      name: "monitor-lease-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: "test",
      metadata: {}
    )
    active_job = DownloadMonitorJob.new
    job = SolidQueue::Job.create!(
      active_job_id: active_job.job_id,
      class_name: "DownloadMonitorJob",
      queue_name: "default",
      arguments: active_job.serialize,
      concurrency_key: key,
      scheduled_at: Time.current
    )
    SolidQueue::ClaimedExecution.create!(job: job, process: process)
    SolidQueue::Semaphore.where(key: key).delete_all
    SolidQueue::Semaphore.create!(key: key, value: 0, expires_at: Time.current)

    leap = [ DownloadMonitorJob.concurrency_duration + 5.seconds, 10.minutes + 5.seconds ].max
    assert_operator leap, :>, 30.minutes
    travel leap do
      SolidQueue::Dispatcher::ConcurrencyMaintenance.new(5.minutes, 500).send(:expire_semaphores)
      assert SolidQueue::Semaphore.exists?(key: key)
    end
  ensure
    if defined?(job) && job
      SolidQueue::ClaimedExecution.where(job_id: job.id).delete_all
      job.delete
    end
    process&.destroy
    SolidQueue::Semaphore.where(key: key).delete_all if defined?(key) && key
  end

  test "skips downloads without external_id" do
    @download.update!(external_id: nil)

    VCR.turned_off do
      stub_qbittorrent_auth

      DownloadMonitorJob.perform_now
      @download.reload

      assert @download.downloading?
      assert_equal 50, @download.progress
    end
  end

  test "flags queued downloads that never reached a client" do
    selected = search_results(:selected_result)
    @download.update_columns(
      status: Download.statuses[:queued],
      external_id: nil,
      download_client_id: nil,
      search_result_id: selected.id,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    )

    SettingsService.set(:download_enqueue_timeout_minutes, 5)

    assert_no_enqueued_jobs(only: DownloadMonitorJob) do
      DownloadMonitorJob.perform_now
    end

    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "never sent to the download client"
    assert_not selected.reload.blocklisted?
  end

  test "skips downloads with disabled client" do
    @qbittorrent.update!(enabled: false)

    VCR.turned_off do
      DownloadMonitorJob.perform_now
      @download.reload

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

  test "fails an abandoned claimed dispatch without an external ID" do
    @download.update_columns(
      status: Download.statuses[:downloading],
      external_id: nil,
      download_client_id: nil,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    )
    SettingsService.set(:download_enqueue_timeout_minutes, 5)

    DownloadMonitorJob.perform_now

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "never sent to the download client"
  end

  test "does not fail an active direct download based on its old creation time" do
    @download.update_columns(
      status: Download.statuses[:downloading],
      external_id: nil,
      download_client_id: nil,
      download_type: "direct",
      created_at: 1.hour.ago,
      updated_at: Time.current
    )

    DownloadMonitorJob.perform_now

    assert @download.reload.downloading?
    assert_not @request.reload.attention_needed?
  end

  test "fails a direct download whose heartbeat went stale" do
    DownloadClient.destroy_all
    stale_at = DownloadMonitorJob::DIRECT_DOWNLOAD_STALE_TIMEOUT.ago - 1.minute
    @download.update_columns(
      status: Download.statuses[:downloading],
      external_id: nil,
      download_client_id: nil,
      download_type: "direct",
      created_at: 1.hour.ago,
      updated_at: stale_at
    )

    DownloadMonitorJob.perform_now

    assert @download.reload.failed?
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "stopped reporting progress"
  end

  test "does not overwrite a direct download completed after the monitor loaded it" do
    stale_at = DownloadMonitorJob::DIRECT_DOWNLOAD_STALE_TIMEOUT.ago - 1.minute
    @download.update_columns(
      status: Download.statuses[:downloading],
      external_id: nil,
      download_type: "direct",
      updated_at: stale_at
    )
    stale_download = Download.find(@download.id)
    @download.update!(status: :completed, progress: 100)

    DownloadMonitorJob.new.send(:handle_stale_direct_download, stale_download)

    assert @download.reload.completed?
    assert_not @request.reload.attention_needed?
  end

  test "does not overwrite a dispatch finalized after the monitor loaded it" do
    @download.update_columns(
      status: Download.statuses[:queued],
      external_id: nil,
      download_type: nil,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    )
    stale_download = Download.find(@download.id)
    @download.update!(
      status: :downloading,
      external_id: "finalized-hash",
      download_type: "torrent",
      download_client: @qbittorrent
    )

    DownloadMonitorJob.new.send(:handle_stale_queued_download, stale_download)

    assert @download.reload.downloading?
    assert_equal "finalized-hash", @download.external_id
    assert_not @request.reload.attention_needed?
  end

  test "ignores a stale client failure after the download was replaced" do
    stale_download = Download.find(@download.id)
    @download.update!(status: :failed)

    DownloadMonitorJob.new.send(:handle_failed, stale_download)

    assert @download.reload.failed?
    assert_not @request.reload.attention_needed?
  end

  test "ignores a stale missing result after the download was replaced" do
    @download.update!(not_found_count: DownloadMonitorJob::NOT_FOUND_THRESHOLD - 1)
    stale_download = Download.find(@download.id)
    @download.update!(status: :failed)

    DownloadMonitorJob.new.send(:handle_missing, stale_download)

    assert @download.reload.failed?
    assert_not @request.reload.attention_needed?
  end

  private

  def with_solid_queue_monitor_jobs
    original_adapter = ActiveJob::Base.queue_adapter
    original_config = SolidQueue::Record.connection_db_config
    monitor_jobs = nil

    SolidQueue::Record.establish_connection(:queue)
    ActiveJob::Base.queue_adapter = :solid_queue
    monitor_jobs = SolidQueue::Job.where(class_name: DownloadMonitorJob.name)
    monitor_jobs.destroy_all

    yield monitor_jobs.where(finished_at: nil).where.not(concurrency_key: nil)
  ensure
    monitor_jobs&.destroy_all
    ActiveJob::Base.queue_adapter = original_adapter
    SolidQueue::Record.establish_connection(original_config)
  end

  def stub_transmission_monitor_torrent(percent_done:, status:, left_until_done: 0, error: 0)
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
            "fields" => DownloadClients::Transmission::JSONRPC_TORRENT_FIELDS
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
                "percent_done" => percent_done,
                "left_until_done" => left_until_done,
                "status" => status,
                "error" => error,
                "error_string" => "",
                "total_size" => 1_073_741_824,
                "download_dir" => "/downloads/complete"
              }
            ]
          },
          "id" => 1
        }.to_json
      )
  end

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

  def stub_deluge_login
    stub_request(:post, "http://localhost:8112/json")
      .with(body: /"auth.login"/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json", "Set-Cookie" => "sessionid=test_session_id; Path=/" },
        body: { result: true, error: nil, id: 1 }.to_json
      )
  end

  def stub_deluge_torrent_info(progress:, state:)
    stub_request(:post, "http://localhost:8112/json")
      .with(body: /"core.get_torrents_status"/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          result: {
            "abc123def456" => {
              "name" => "Test Audiobook",
              "progress" => progress,
              "state" => state,
              "total_size" => 1_073_741_824,
              "download_location" => "/downloads/complete",
              "save_path" => "/downloads/complete"
            }
          },
          error: nil,
          id: 1
        }.to_json
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

class DownloadMonitorReadyLeaseTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    DownloadMonitorJob.clear_schedule!
    SettingsService.set(:download_check_interval, 60)
    @queue = "download-monitor-ready-#{SecureRandom.hex(4)}"
    @client = DownloadClient.create!(
      name: "Ready lease qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
  end

  teardown do
    DownloadMonitorJob.clear_schedule!
    Rails.cache = @original_cache
    @client&.destroy
  end

  test "an expired ready monitor does not overlap a later tick while workers drain" do
    start = Time.zone.parse("2026-08-26 12:00:00")
    entered = Queue.new
    release = Queue.new
    gate = Mutex.new
    state = { inside: 0, max_inside: 0 }
    processes = []
    install_overlap_probe!(gate, entered, release, state)

    with_solid_queue_monitors do
      begin
        processes = register_workers(3)
        travel_to start do
          DownloadMonitorJob.set(queue: @queue).perform_later(scheduled: true)
          assert_equal 1, ready_monitor_count
          assert SolidQueue::Semaphore.exists?(key: DownloadMonitorJob.new.concurrency_key)
        end

        leap = DownloadMonitorJob.concurrency_duration + 1.minute
        assert_operator leap, :>, 30.minutes
        travel_to start + leap do
          SolidQueue::Dispatcher::ConcurrencyMaintenance.new(5.minutes, 500).send(:expire_semaphores)
          assert_equal 1, ready_monitor_count
          DownloadMonitorJob.set(queue: @queue).perform_later(scheduled: true)
          claim_and_perform(processes.first, 1)
          wait_for("the waiting monitor to start") { entered.size >= 1 }
        end

        travel_to start + leap + 1.minute do
          processes.each { |process| claim_and_perform(process, 1) }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          until gate.synchronize { state[:max_inside] } > 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.02
          end
          assert_equal 1, gate.synchronize { state[:max_inside] }
        end
      ensure
        3.times { release << true }
        join_worker_threads
      end
    end
  ensure
    3.times { release << true } if defined?(release) && release
    join_worker_threads
    restore_scan_probe!
    processes&.each { |process| process.deregister rescue nil }
    raise @worker_error if @worker_error && !$!
  end

  private

  def install_overlap_probe!(gate, entered, release, state)
    @original_monitor = DownloadMonitorJob.instance_method(:monitor_active_downloads)
    DownloadMonitorJob.define_method(:monitor_active_downloads) do
      gate.synchronize do
        state[:inside] += 1
        state[:max_inside] = state[:inside] if state[:inside] > state[:max_inside]
      end
      entered << true
      release.pop
      gate.synchronize { state[:inside] -= 1 }
    end
    DownloadMonitorJob.send(:private, :monitor_active_downloads)
  end

  def restore_scan_probe!
    return unless @original_monitor

    DownloadMonitorJob.define_method(:monitor_active_downloads, @original_monitor)
    DownloadMonitorJob.send(:private, :monitor_active_downloads)
    @original_monitor = nil
  end

  def with_solid_queue_monitors
    original_config = SolidQueue::Record.connection_db_config
    SolidQueue::Record.establish_connection(:queue)
    switch_to_solid_queue!
    clear_monitor_queue!
    @worker_threads = []
    @worker_error = nil
    yield
  ensure
    begin
      join_worker_threads
      clear_monitor_queue!
    ensure
      SolidQueue::Record.establish_connection(original_config) if original_config
      restore_test_adapter!
    end
  end

  def register_workers(count)
    count.times.map do |index|
      SolidQueue::Process.register(
        kind: "Worker",
        name: "monitor-ready-#{index}-#{SecureRandom.hex(4)}",
        pid: Process.pid,
        hostname: "test",
        metadata: {}
      )
    end
  end

  def claim_and_perform(process, limit)
    claimed = SolidQueue::ReadyExecution.claim(@queue, limit, process.id)
    claimed.each do |execution|
      @worker_threads << Thread.new(execution) do |claimed_execution|
        Thread.current.report_on_exception = false
        Thread.current.abort_on_exception = false
        claimed_execution.perform
      rescue Exception => error
        @worker_error = error
      end
    end
    claimed
  end

  def ready_monitor_count
    SolidQueue::ReadyExecution.joins(:job).where(
      queue_name: @queue,
      solid_queue_jobs: { class_name: "DownloadMonitorJob" }
    ).count
  end

  def join_worker_threads
    @worker_threads&.each { |thread| thread.join(5) }
  end

  def clear_monitor_queue!
    SolidQueue::Job.uncached do
      jobs = SolidQueue::Job.where(class_name: "DownloadMonitorJob")
      ids = jobs.ids
      if ids.any?
        SolidQueue::BlockedExecution.where(job_id: ids).delete_all
        SolidQueue::ClaimedExecution.where(job_id: ids).delete_all
        SolidQueue::ReadyExecution.where(job_id: ids).delete_all
        SolidQueue::FailedExecution.where(job_id: ids).delete_all
        SolidQueue::ScheduledExecution.where(job_id: ids).delete_all
        SolidQueue::RecurringExecution.where(job_id: ids).delete_all
        jobs.delete_all
      end
      SolidQueue::Semaphore.where(key: DownloadMonitorJob.new.concurrency_key).delete_all
    end
  end

  def switch_to_solid_queue!
    return if @switched_adapter

    @original_queue_adapter = ActiveJob::Base._queue_adapter
    @original_test_adapter = ActiveJob::Base._test_adapter
    @switched_adapter = true
    ActiveJob::Base.disable_test_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
  end

  def restore_test_adapter!
    return unless @switched_adapter

    if @original_queue_adapter
      ActiveJob::Base.queue_adapter = @original_queue_adapter
    else
      ActiveJob::Base.queue_adapter = :test
    end
    if @original_test_adapter
      ActiveJob::Base.enable_test_adapter(@original_test_adapter)
    else
      ActiveJob::Base.disable_test_adapter
    end
    @switched_adapter = false
  end

  def wait_for(description)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until yield
      raise "timed out waiting for #{description} #{@worker_error}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end
end
