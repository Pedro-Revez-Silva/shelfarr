# frozen_string_literal: true

# Recurring job that monitors system health by checking all configured services
class HealthCheckJob < ApplicationJob
  queue_as :default

  def perform(service: nil)
    if service.present?
      run_check_for(service)
    else
      check_prowlarr
      check_download_clients
      check_download_paths
      check_output_paths
      check_audiobookshelf
      check_hardcover
      schedule_next_run
    end
  end

  private

  def run_check_for(service)
    case service.to_s
    when "prowlarr" then check_prowlarr
    when "download_client" then check_download_clients
    when "download_paths" then check_download_paths
    when "output_paths" then check_output_paths
    when "audiobookshelf" then check_audiobookshelf
    when "hardcover" then check_hardcover
    else
      Rails.logger.warn "[HealthCheckJob] Unknown service: #{service}"
    end
  end

  def check_prowlarr
    health = SystemHealth.for_service("prowlarr")

    unless ProwlarrClient.configured?
      health.mark_not_configured!
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
      health.mark_not_configured!(message: "No download clients configured")
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

  def check_download_paths
    health = SystemHealth.for_service("download_paths")
    clients = DownloadClient.enabled.torrent_clients.to_a

    if clients.empty?
      health.mark_not_configured!(message: "No torrent clients configured")
      return
    end

    issues = []
    local_path = SettingsService.get(:download_local_path, default: "/downloads")

    unless Dir.exist?(local_path)
      issues << "Base download path '#{local_path}' does not exist in container"
    end

    clients.each do |client|
      # Check client-specific download_path if set
      if client.download_path.present? && !Dir.exist?(client.download_path)
        issues << "#{client.name}: configured download path '#{client.download_path}' does not exist"
      end

      # Check category subfolder only for qBittorrent (uses category-based save paths)
      if client.qbittorrent? && client.category.present?
        base = client.download_path.presence || local_path
        if Dir.exist?(base)
          category_path = File.join(base, client.category)
          unless Dir.exist?(category_path)
            issues << "#{client.name}: category folder '#{category_path}' not found — " \
                      "ensure your Docker mount includes the '#{client.category}' subfolder"
          end
        end
      end

      # Query qBit for save path info (diagnostics only)
      if client.qbittorrent?
        begin
          diagnostics = client.adapter.connection_diagnostics
          if diagnostics
            save_path = diagnostics[:save_path]
            cat_path = diagnostics[:category_save_path]
            Rails.logger.info "[HealthCheckJob] #{client.name}: qBit save_path=#{save_path}, " \
                              "category_save_path=#{cat_path.presence || '(default)'}"
          end
        rescue => e
          Rails.logger.warn "[HealthCheckJob] Path diagnostics for #{client.name} failed: #{e.message}"
        end
      end
    end

    if issues.empty?
      health.check_succeeded!(message: "Download paths accessible")
    else
      health.check_failed!(
        message: issues.join("; ").truncate(500),
        degraded: issues.none? { |i| i.include?("does not exist in container") }
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
      health.mark_not_configured!
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

  def check_hardcover
    health = SystemHealth.for_service("hardcover")

    unless HardcoverClient.configured?
      health.mark_not_configured!
      return
    end

    if HardcoverClient.test_connection
      health.check_succeeded!(message: "Connection successful")
    else
      health.check_failed!(message: "Failed to connect to Hardcover")
    end
  rescue HardcoverClient::AuthenticationError => e
    health.check_failed!(message: "Authentication failed: #{e.message}")
  rescue HardcoverClient::ConnectionError => e
    health.check_failed!(message: "Connection error: #{e.message}")
  rescue => e
    health.check_failed!(message: "Error: #{e.message}")
    Rails.logger.error "[HealthCheckJob] Hardcover check failed: #{e.message}"
  end

  def schedule_next_run
    interval = SettingsService.get(:health_check_interval, default: 300)
    HealthCheckJob.set(wait: interval.seconds).perform_later
  end
end
