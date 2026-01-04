# frozen_string_literal: true

require "test_helper"

class HealthCheckJobTest < ActiveJob::TestCase
  setup do
    SystemHealth.destroy_all
    Thread.current[:qbittorrent_sessions] = {}
  end

  test "schedules next run after checking" do
    assert_enqueued_with(job: HealthCheckJob) do
      HealthCheckJob.perform_now
    end
  end

  test "uses configurable interval for next run" do
    Setting.find_or_create_by(key: "health_check_interval").update!(
      value: "600",
      value_type: "integer",
      category: "health"
    )

    HealthCheckJob.perform_now

    enqueued = enqueued_jobs.find { |j| j[:job] == HealthCheckJob }
    assert enqueued
  end

  # Prowlarr tests
  test "marks prowlarr as healthy when not configured" do
    Setting.where(key: %w[prowlarr_url prowlarr_api_key]).destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("prowlarr")
    assert health.healthy?
    assert_includes health.message, "Not configured"
  end

  test "marks prowlarr as healthy when configured and connected" do
    setup_prowlarr_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/health")
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
      stub_request(:get, "http://localhost:9696/api/v1/health")
        .to_return(status: 500)

      HealthCheckJob.perform_now

      health = SystemHealth.for_service("prowlarr")
      assert health.down?
    end
  end

  # Download client tests
  test "marks download_client as healthy when no clients configured" do
    DownloadClient.destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("download_client")
    assert health.healthy?
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
      stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(status: 200, headers: { "Set-Cookie" => "SID=test; path=/" }, body: "Ok.")
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
  test "marks audiobookshelf as healthy when not configured" do
    Setting.where(key: %w[audiobookshelf_url audiobookshelf_api_key]).destroy_all

    HealthCheckJob.perform_now

    health = SystemHealth.for_service("audiobookshelf")
    assert health.healthy?
    assert_includes health.message, "Not configured"
  end

  test "marks audiobookshelf as healthy when configured and connected" do
    setup_audiobookshelf_settings

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "libraries" => [{ "id" => "lib-1", "name" => "Audiobooks" }] }.to_json
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

  def stub_qbittorrent_auth_success
    stub_request(:post, "http://localhost:8080/api/v2/auth/login")
      .to_return(
        status: 200,
        headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
        body: "Ok."
      )
  end
end
