# frozen_string_literal: true

require "test_helper"

class HealthCheckJobTest < ActiveJob::TestCase
  setup do
    SystemHealth.destroy_all
    DownloadClient.destroy_all
    Setting.where(key: "health_check_interval").delete_all
    Thread.current[:qbittorrent_sessions] = {}
  end

  test "does not schedule next run after checking (recurring job handles scheduling)" do
    assert_no_enqueued_jobs(only: HealthCheckJob) do
      HealthCheckJob.perform_now
    end
  end

  test "cleanup discards only identifiable legacy delayed full-check jobs" do
    SolidQueue::Record.establish_connection(:queue)
    legacy = create_queue_health_job(scheduled_at: 5.minutes.from_now)
    manual = create_queue_health_job(scheduled_at: Time.current)
    targeted = create_queue_health_job(
      scheduled_at: 5.minutes.from_now,
      arguments: { service: "hardcover" }
    )
    recurring = create_queue_health_job(
      scheduled_at: 5.minutes.from_now,
      arguments: { scheduled: true }
    )
    SolidQueue::RecurringExecution.create!(
      job: recurring,
      task_key: "health_check",
      run_at: 5.minutes.from_now
    )
    claimed = create_queue_health_job(scheduled_at: 5.minutes.from_now)
    claimed.scheduled_execution.destroy!
    process = SolidQueue::Process.register(
      kind: "Worker",
      name: "health-check-cleanup-test-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: "test",
      metadata: {}
    )
    SolidQueue::ClaimedExecution.create!(job: claimed, process: process)

    assert_equal 1, HealthCheckJob.discard_legacy_scheduled_chains!

    assert_not SolidQueue::Job.exists?(legacy.id)
    [ manual, targeted, recurring, claimed ].each do |preserved|
      assert SolidQueue::Job.exists?(preserved.id), "expected job #{preserved.id} to be preserved"
    end
  end

  test "scheduled checks honor the configured interval on minute boundaries" do
    SettingsService.set(:health_check_interval, 600)

    travel_to Time.zone.parse("2026-08-26 12:00:00") do
      SystemHealth::SERVICES.each do |service|
        SystemHealth.create!(
          service: service,
          status: :not_configured,
          last_check_at: 9.minutes.ago
        )
      end

      job = HealthCheckJob.new
      assert_not job.send(:scheduled_health_check_due?)

      SystemHealth.update_all(last_check_at: 10.minutes.ago)
      assert job.send(:scheduled_health_check_due?)
    end
  end

  test "scheduled checks run when a service has never been checked" do
    SystemHealth::SERVICES.each do |service|
      SystemHealth.create!(service: service, status: :not_configured, last_check_at: 1.minute.ago)
    end
    SystemHealth.find_by!(service: "hardcover").update_column(:last_check_at, nil)

    assert HealthCheckJob.new.send(:scheduled_health_check_due?)
  end

  # Single service check
  test "checks only the specified service when service param is given" do
    Setting.where(key: %w[prowlarr_url prowlarr_api_key]).destroy_all

    # Should only check prowlarr and NOT schedule next run
    assert_no_enqueued_jobs(only: HealthCheckJob) do
      HealthCheckJob.perform_now(service: "prowlarr")
    end

    health = SystemHealth.for_service("prowlarr")
    assert health.not_configured?
  end

  # Prowlarr tests
  test "marks prowlarr as not_configured when not configured" do
    Setting.where(key: %w[prowlarr_url prowlarr_api_key]).destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("prowlarr")
    assert health.not_configured?
    assert_includes health.message, "Not configured"
  end

  test "marks prowlarr as healthy when configured and connected" do
    setup_prowlarr_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .to_return(status: 200, body: "[]")

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("prowlarr")
      assert health.healthy?
      assert_includes health.message, "successful"
    end
  end

  test "marks prowlarr as down when connection fails" do
    setup_prowlarr_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .to_return(status: 500)

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("prowlarr")
      assert health.down?
    end
  end

  test "marks indexer as healthy when jackett is selected and connected" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with(query: hash_including("apikey" => "jackett-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      HealthCheckJob.perform_now(service: "indexer")

      health = SystemHealth.for_service("indexer")
      assert health.healthy?
      assert_includes health.message, "successful"
    end
  end

  # Download client tests
  test "marks download_client as not_configured when no clients configured" do
    DownloadClient.destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("download_client")
    assert health.not_configured?
    assert_includes health.message, "No download clients configured"
  end

  test "marks download_client as healthy when all clients connect" do
    client = create_download_client

    VCR.turned_off do
      stub_qbittorrent_auth_success

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("download_client")
      assert health.healthy?
      assert_includes health.message, "1 clients connected"
    end
  end

  test "marks download_client as down when all clients fail" do
    client = create_download_client

    VCR.turned_off do
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("download_client")
      assert health.down?
      assert_includes health.message, client.name
    end
  end

  test "marks download_client as degraded when some clients fail" do
    client1 = create_download_client(name: "Working Client", url: "http://localhost:8080")
    client2 = create_download_client(name: "Failing Client", url: "http://localhost:9090")

    VCR.turned_off do
      # First client succeeds
      stub_qbittorrent_connection("http://localhost:8080", session_id: "test")
      # Second client fails
      stub_request(:post, "http://localhost:9090/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("download_client")
      assert health.degraded?
      assert_includes health.message, "1/2 working"
      assert_includes health.message, "Failing Client"
    end
  end

  # Download paths tests
  test "marks download_paths as not_configured when no torrent clients exist" do
    DownloadClient.destroy_all

    HealthCheckJob.perform_now(service: "download_paths")

    health = SystemHealth.for_service("download_paths")
    assert health.not_configured?
    assert_includes health.message, "No torrent clients"
  end

  test "marks download_paths as healthy when local path and category folder exist" do
    Dir.mktmpdir do |download_dir|
      category_dir = File.join(download_dir, "shelfarr")
      FileUtils.mkdir_p(category_dir)

      setup_download_paths(download_dir)
      client = create_download_client(name: "Path Test Client")
      client.update!(category: "shelfarr")

      VCR.turned_off do
        stub_qbittorrent_auth_success

        # Stub diagnostics endpoints
        stub_request(:get, "http://localhost:8080/api/v2/app/preferences")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "save_path" => "/mnt/media/Torrents" }.to_json
          )
        stub_request(:get, "http://localhost:8080/api/v2/torrents/categories")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "shelfarr" => { "name" => "shelfarr", "savePath" => "" } }.to_json
          )

        HealthCheckJob.perform_now(service: "download_paths")

        health = SystemHealth.for_service("download_paths")
        assert health.healthy?
        assert_includes health.message, "accessible"
      end
    end
  end

  test "marks download_paths as failed when base local path does not exist" do
    setup_download_paths("/nonexistent/downloads")
    client = create_download_client(name: "Path Fail Client")

    VCR.turned_off do
      stub_qbittorrent_auth_success

      stub_request(:get, "http://localhost:8080/api/v2/app/preferences")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "save_path" => "/mnt/media/Torrents" }.to_json
        )
      stub_request(:get, "http://localhost:8080/api/v2/torrents/categories")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {}.to_json
        )

      HealthCheckJob.perform_now(service: "download_paths")

      health = SystemHealth.for_service("download_paths")
      assert health.down?
      assert_includes health.message, "does not exist"
    end
  end

  test "marks download_paths as degraded when category folder is missing for qbittorrent" do
    Dir.mktmpdir do |download_dir|
      # Don't create the category subfolder
      setup_download_paths(download_dir)
      client = create_download_client(name: "Cat Missing Client")
      client.update!(category: "shelfarr")

      VCR.turned_off do
        stub_qbittorrent_auth_success

        stub_request(:get, "http://localhost:8080/api/v2/app/preferences")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "save_path" => download_dir }.to_json
          )
        stub_request(:get, "http://localhost:8080/api/v2/torrents/categories")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "shelfarr" => { "name" => "shelfarr", "savePath" => "" } }.to_json
          )

        HealthCheckJob.perform_now(service: "download_paths")

        health = SystemHealth.for_service("download_paths")
        assert health.degraded?
        assert_includes health.message, "category folder"
      end
    end
  end

  test "does not check category folder for non-qbittorrent clients" do
    Dir.mktmpdir do |download_dir|
      # No category subfolder exists, but that's fine for Transmission
      setup_download_paths(download_dir)
      DownloadClient.destroy_all
      DownloadClient.create!(
        name: "Transmission Client",
        client_type: "transmission",
        url: "http://localhost:9091",
        username: "admin",
        password: "password",
        category: "shelfarr",
        priority: 0,
        enabled: true
      )

      HealthCheckJob.perform_now(service: "download_paths")

      health = SystemHealth.for_service("download_paths")
      assert health.healthy?
      assert_includes health.message, "accessible"
    end
  end

  test "does not require category folder when client download_path is set" do
    Dir.mktmpdir do |client_path|
      Dir.mktmpdir do |local_path|
        setup_download_paths(local_path)
        client = create_download_client(name: "Custom Path Client")
        client.update!(category: "shelfarr", download_path: client_path)

        VCR.turned_off do
          stub_qbittorrent_auth_success

          HealthCheckJob.perform_now(service: "download_paths")

          health = SystemHealth.for_service("download_paths")
          assert health.healthy?
          assert_includes health.message, "accessible"
          refute_includes health.message, "category folder"
        end
      end
    end
  end

  test "marks download_paths as degraded when client download_path does not exist" do
    Dir.mktmpdir do |local_path|
      missing_client_path = File.join(local_path, "missing-client-downloads")

      setup_download_paths(local_path)
      client = create_download_client(name: "Missing Custom Path Client")
      client.update!(category: "shelfarr", download_path: missing_client_path)

      VCR.turned_off do
        stub_qbittorrent_auth_success

        HealthCheckJob.perform_now(service: "download_paths")

        health = SystemHealth.for_service("download_paths")
        assert health.degraded?
        assert_includes health.message, "configured download path"
        assert_includes health.message, missing_client_path
      end
    end
  end

  # Output paths tests
  test "marks output_paths as healthy when paths exist and are writable" do
    Dir.mktmpdir do |audiobook_dir|
      Dir.mktmpdir do |ebook_dir|
        setup_output_paths(audiobook_dir, ebook_dir)

        HealthCheckJob.perform_now

        health = SystemHealth.for_service("output_paths")
        assert health.healthy?
        assert_includes health.message, "accessible"
      end
    end
  end

  test "reports retained broad legacy direct staging without exposing its output root" do
    Dir.mktmpdir("legacy-audiobooks") do |audiobook_dir|
      Dir.mktmpdir("legacy-ebooks-private-root") do |ebook_dir|
        setup_output_paths(audiobook_dir, ebook_dir)
        legacy = File.join(ebook_dir, DirectDownloadFileService::LEGACY_STAGING_DIRECTORY)
        FileUtils.mkdir_p(legacy)
        File.chmod(0o777, legacy)

        HealthCheckJob.perform_now(service: "output_paths")

        health = SystemHealth.for_service("output_paths")
        assert health.degraded?
        assert_includes health.message, "Ebook legacy direct-download staging"
        assert_includes health.message, "0777"
        assert_includes health.message, "retained"
        assert_includes health.message, DirectDownloadFileService::STAGING_DIRECTORY
        refute_includes health.message, ebook_dir
      end
    end
  end

  test "reports nonempty private legacy direct staging without exposing its output root" do
    Dir.mktmpdir("legacy-audiobooks") do |audiobook_dir|
      Dir.mktmpdir("legacy-ebooks-private-root") do |ebook_dir|
        setup_output_paths(audiobook_dir, ebook_dir)
        legacy = File.join(ebook_dir, DirectDownloadFileService::LEGACY_STAGING_DIRECTORY)
        FileUtils.mkdir_p(File.join(legacy, DirectDownloadFileService::DIRECT_DOWNLOADS_DIRECTORY))
        File.chmod(0o700, legacy)

        HealthCheckJob.perform_now(service: "output_paths")

        health = SystemHealth.for_service("output_paths")
        assert health.degraded?
        assert_includes health.message, "Ebook legacy direct-download staging"
        assert_includes health.message, "contains retained entries"
        assert_includes health.message, DirectDownloadFileService::STAGING_DIRECTORY
        refute_includes health.message, ebook_dir
      end
    end
  end

  test "marks output_paths as degraded when one path has issues" do
    Dir.mktmpdir do |valid_dir|
      setup_output_paths(valid_dir, "/nonexistent/path")

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("output_paths")
      assert health.degraded?
      assert_includes health.message, "Ebook path"
    end
  end

  test "marks output_paths as down when both paths have issues" do
    setup_output_paths("/nonexistent/audiobooks", "/nonexistent/ebooks")

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("output_paths")
    assert health.down?
  end

  test "marks output_paths as down when paths not configured" do
    # Set paths to empty strings (blank = not configured)
    Setting.find_or_create_by(key: "audiobook_output_path").update!(
      value: "",
      value_type: "string",
      category: "paths"
    )
    Setting.find_or_create_by(key: "ebook_output_path").update!(
      value: "",
      value_type: "string",
      category: "paths"
    )

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("output_paths")
    assert health.down?
    assert_includes health.message, "not configured"
  end

  # Audiobookshelf tests
  test "marks audiobookshelf as not_configured when not configured" do
    Setting.where(key: %w[audiobookshelf_url audiobookshelf_api_key]).destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("audiobookshelf")
    assert health.not_configured?
    assert_includes health.message, "Not configured"
  end

  test "marks audiobookshelf as healthy when configured and connected" do
    setup_audiobookshelf_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "libraries" => [ { "id" => "lib-1", "name" => "Audiobooks" } ] }.to_json
        )

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("audiobookshelf")
      assert health.healthy?
      assert_includes health.message, "successful"
    end
  end

  test "marks audiobookshelf as down when connection fails" do
    setup_audiobookshelf_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(status: 401)

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("audiobookshelf")
      assert health.down?
    end
  end

  private

  def create_queue_health_job(scheduled_at:, arguments: {})
    active_job = arguments.empty? ? HealthCheckJob.new : HealthCheckJob.new(**arguments)
    SolidQueue::Job.create!(
      active_job_id: active_job.job_id,
      class_name: "HealthCheckJob",
      queue_name: "default",
      arguments: active_job.serialize,
      scheduled_at: scheduled_at
    )
  end

  def create_download_client(name: "Test Client", url: "http://localhost:8080")
    DownloadClient.create!(
      name: name,
      client_type: "qbittorrent",
      url: url,
      username: "admin",
      password: "password",
      priority: DownloadClient.count,
      enabled: true
    )
  end

  def setup_prowlarr_settings
    Setting.find_or_create_by(key: "prowlarr_url").update!(
      value: "http://localhost:9696",
      value_type: "string",
      category: "prowlarr"
    )
    Setting.find_or_create_by(key: "prowlarr_api_key").update!(
      value: "test-api-key",
      value_type: "string",
      category: "prowlarr"
    )
  end

  def setup_audiobookshelf_settings
    Setting.find_or_create_by(key: "audiobookshelf_url").update!(
      value: "http://localhost:13378",
      value_type: "string",
      category: "audiobookshelf"
    )
    Setting.find_or_create_by(key: "audiobookshelf_api_key").update!(
      value: "test-api-key",
      value_type: "string",
      category: "audiobookshelf"
    )
  end

  def setup_output_paths(audiobook_path, ebook_path)
    Setting.find_or_create_by(key: "audiobook_output_path").update!(
      value: audiobook_path,
      value_type: "string",
      category: "paths"
    )
    Setting.find_or_create_by(key: "ebook_output_path").update!(
      value: ebook_path,
      value_type: "string",
      category: "paths"
    )
  end

  def setup_download_paths(local_path)
    Setting.find_or_create_by(key: "download_local_path").update!(
      value: local_path,
      value_type: "string",
      category: "paths"
    )
  end

  def stub_qbittorrent_auth_success
    stub_qbittorrent_connection("http://localhost:8080")
  end
end
