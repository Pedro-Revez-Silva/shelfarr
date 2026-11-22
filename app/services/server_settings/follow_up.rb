# frozen_string_literal: true

module ServerSettings
  class FollowUp
    LOG_TAG = "[SettingsController]"

    def self.call(changed_keys)
      new(changed_keys).call
    end

    def initialize(changed_keys)
      @changed_keys = changed_keys.map(&:to_s)
    end

    def call
      return if changed_keys.blank?

      reset_library_platform if changed?(&method(:library_platform_setting_key?))
      run_health_check("indexer") if changed?(&method(:indexer_setting_key?))
      FlaresolverrClient.reset_connection! if changed? { |key| key == "flaresolverr_url" }
      AnnaArchiveClient.reset_connection! if starts_with?("anna_archive")
      ZLibraryClient.reset_connection! if starts_with?("zlibrary")
      GutenbergClient.reset_connection! if starts_with?("gutenberg")
      LibrivoxClient.reset_connection! if starts_with?("librivox")
      MetadataProviderStatus.clear_after_credential_change_for_settings!(changed_keys) if changed? { |key| MetadataProviderStatus.provider_for_setting(key).present? }
      reset_hardcover if starts_with?("hardcover")
      GoogleBooksClient.reset_connection! if starts_with?("google_books")
      OpenLibraryClient.reset_connection! if starts_with?("open_library")
      sync_telegram_transport if starts_with?("telegram")
      run_health_check_now("output_paths") if starts_with?("audiobook_output_path") || starts_with?("ebook_output_path")
      run_health_check_now("download_paths") if starts_with?("download_local_path") || starts_with?("download_remote_path")
      nil
    rescue StandardError => e
      Rails.logger.error("#{LOG_TAG} Settings saved but a follow-up action failed: #{e.class}: #{e.message}")
      e
    end

    private

    attr_reader :changed_keys

    def changed?(&predicate)
      changed_keys.any?(&predicate)
    end

    def starts_with?(prefix)
      changed? { |key| key.start_with?(prefix) }
    end

    def reset_library_platform
      LibraryPlatformClient.reset_connections!
      AudiobookshelfLibrarySyncJob.perform_later if LibraryPlatformClient.configured?
      run_health_check("audiobookshelf")
    end

    def reset_hardcover
      HardcoverClient.reset_connection!
      run_health_check("hardcover")
    end

    def run_health_check(service_name)
      HealthCheckJob.perform_later(service: service_name)
    rescue => e
      Rails.logger.warn "#{LOG_TAG} Failed to enqueue health check for #{service_name}: #{e.message}"
    end

    def run_health_check_now(service_name)
      HealthCheckJob.perform_now(service: service_name)
    rescue => e
      Rails.logger.warn "#{LOG_TAG} Failed to run health check for #{service_name}: #{e.message}"
    end

    def sync_telegram_transport
      TelegramPollingJob.clear_schedule!
      return unless Integrations::Telegram::Configuration.polling? && Integrations::Telegram::Configuration.configured?

      begin
        Integrations::Telegram::Client.delete_webhook!(drop_pending_updates: false)
      rescue => e
        Rails.logger.warn "#{LOG_TAG} Failed to clear Telegram webhook for polling mode: #{e.message}"
      end
      TelegramPollingJob.ensure_running!
    end

    def indexer_setting_key?(key)
      key.start_with?("indexer_") || key.start_with?("prowlarr") || key.start_with?("jackett") || key.start_with?("newznab")
    end

    def library_platform_setting_key?(key)
      key.start_with?("audiobookshelf") || key.start_with?("bookorbit") || key.start_with?("grimmory") || key == "library_platform"
    end
  end
end
