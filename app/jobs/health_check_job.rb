# frozen_string_literal: true

# Recurring job that monitors system health by checking all configured services
class HealthCheckJob < ApplicationJob
  queue_as :default

  def perform
    check_prowlarr
    check_download_clients
    check_output_paths
    check_audiobookshelf
    schedule_next_run
  end

  private

  def check_prowlarr
    health = SystemHealth.for_service("prowlarr")

    unless ProwlarrClient.configured?
      health.check_succeeded!(message: "Not configured")
      return
    end

    if ProwlarrClient.test_connection
      health.check_succeeded!(message: "Connection successful")
    else
      health.check_failed!(message: "Failed to connect to Prowlarr")
    end
  rescue ProwlarrClient::AuthenticationError => e
    health.check_failed!(message: "Authentication failed: #{e.message}")
  rescue ProwlarrClient::ConnectionError => e
    health.check_failed!(message: "Connection error: #{e.message}")
  rescue => e
    health.check_failed!(message: "Error: #{e.message}")
    Rails.logger.error "[HealthCheckJob] Prowlarr check failed: #{e.message}"
  end

  def check_download_clients
    health = SystemHealth.for_service("download_client")
    clients = DownloadClient.enabled.to_a

    if clients.empty?
      health.check_succeeded!(message: "No download clients configured")
      return
    end

    results = clients.map do |client|
      success = begin
        client.test_connection
      rescue => e
        Rails.logger.error "[HealthCheckJob] Download client #{client.name} check failed: #{e.message}"
        false
      end
      { client: client, success: success }
    end

    successful = results.count { |r| r[:success] }
    failed = results.count { |r| !r[:success] }

    if failed == 0
      health.check_succeeded!(message: "All #{successful} clients connected")
    elsif successful == 0
      names = results.reject { |r| r[:success] }.map { |r| r[:client].name }.join(", ")
      health.check_failed!(message: "All clients failed: #{names}")
    else
      names = results.reject { |r| r[:success] }.map { |r| r[:client].name }.join(", ")
      health.check_failed!(
        message: "#{successful}/#{clients.size} working. Failed: #{names}",
        degraded: true
      )
    end
  end

  def check_output_paths
    health = SystemHealth.for_service("output_paths")
    issues = []

    audiobook_path = SettingsService.get(:audiobook_output_path)
    ebook_path = SettingsService.get(:ebook_output_path)

    issues << check_path("Audiobook", audiobook_path)
    issues << check_path("Ebook", ebook_path)
    issues.compact!

    if issues.empty?
      health.check_succeeded!(message: "All output paths accessible")
    elsif issues.size == 1
      health.check_failed!(message: issues.first, degraded: true)
    else
      health.check_failed!(message: issues.join("; "))
    end
  end

  def check_path(name, path)
    return "#{name} path not configured" if path.blank?
    return "#{name} path does not exist" unless Dir.exist?(path)
    return "#{name} path not writable" unless File.writable?(path)
    nil
  end

  def check_audiobookshelf
    health = SystemHealth.for_service("audiobookshelf")

    unless AudiobookshelfClient.configured?
      health.check_succeeded!(message: "Not configured")
      return
    end

    if AudiobookshelfClient.test_connection
      health.check_succeeded!(message: "Connection successful")
    else
      health.check_failed!(message: "Failed to connect to Audiobookshelf")
    end
  rescue AudiobookshelfClient::AuthenticationError => e
    health.check_failed!(message: "Authentication failed: #{e.message}")
  rescue AudiobookshelfClient::ConnectionError => e
    health.check_failed!(message: "Connection error: #{e.message}")
  rescue => e
    health.check_failed!(message: "Error: #{e.message}")
    Rails.logger.error "[HealthCheckJob] Audiobookshelf check failed: #{e.message}"
  end

  def schedule_next_run
    interval = SettingsService.get(:health_check_interval, default: 300)
    HealthCheckJob.set(wait: interval.seconds).perform_later
  end
end
