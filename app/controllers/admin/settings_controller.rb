module Admin
  class SettingsController < BaseController
    before_action :ensure_settings_seeded, only: :index

    def index
      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
      load_telegram_chat_authorizations
      load_audiobookshelf_cache_summary
    end

    def update
      key = params[:id]
      value = params[:setting][:value]

      unless preserve_blank_secret?(key, value)
        validate_path_template!(key, value)
        SettingsService.set(key, value)
        handle_settings_side_effects([ key.to_s ])
      end

      respond_to do |format|
        format.html { redirect_to admin_settings_path, notice: "Setting updated." }
        format.turbo_stream
      end
    rescue ArgumentError => e
      redirect_to admin_settings_path, alert: e.message
    end

    def bulk_update
      errors = []
      changed_keys = []

      params[:settings]&.each do |key, value|
        next if preserve_blank_secret?(key, value)

        error = validate_path_template(key, value)
        if error
          errors << "#{key.to_s.titleize}: #{error}"
        else
          SettingsService.set(key, value)
          changed_keys << key.to_s
        end
      end

      handle_settings_side_effects(changed_keys)

      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
      load_telegram_chat_authorizations
      load_audiobookshelf_cache_summary

      respond_to do |format|
        if errors.any?
          format.html { redirect_to admin_settings_path, alert: errors.join(". ") }
          format.turbo_stream do
            flash.now[:alert] = errors.join(". ")
            render turbo_stream: [
              turbo_stream.update("settings-form", partial: "admin/settings/form"),
              turbo_stream.update("flash", partial: "shared/flash")
            ]
          end
        else
          format.html { redirect_to admin_settings_path, notice: "Settings updated successfully." }
          format.turbo_stream do
            flash.now[:notice] = "Settings updated successfully."
            render turbo_stream: [
              turbo_stream.update("settings-form", partial: "admin/settings/form"),
              turbo_stream.update("flash", partial: "shared/flash")
            ]
          end
        end
      end
    rescue ArgumentError => e
      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
      load_telegram_chat_authorizations
      load_audiobookshelf_cache_summary

      respond_to do |format|
        format.html { redirect_to admin_settings_path, alert: e.message }
        format.turbo_stream do
          flash.now[:alert] = e.message
          render turbo_stream: [
            turbo_stream.update("settings-form", partial: "admin/settings/form"),
            turbo_stream.update("flash", partial: "shared/flash")
          ]
        end
      end
    end

    def test_indexer
      health = SystemHealth.for_service("indexer")

      unless IndexerClient.configured?
        health.mark_not_configured!
        respond_with_flash(alert: "#{IndexerClient.display_name} is not configured. Select a provider and enter connection details first.")
        return
      end

      if IndexerClient.test_connection
        health.check_succeeded!(message: "Connection successful")
        respond_with_flash(notice: "#{IndexerClient.display_name} connection successful!")
      else
        health.check_failed!(message: "Failed to connect to #{IndexerClient.display_name}")
        respond_with_flash(alert: "#{IndexerClient.display_name} connection failed.")
      end
    rescue IndexerClients::Base::Error => e
      health&.check_failed!(message: e.message)
      respond_with_flash(alert: "#{IndexerClient.display_name} error: #{e.message}")
    end

    def test_prowlarr
      test_indexer
    end

    def test_audiobookshelf
      health = SystemHealth.for_service("audiobookshelf")

      unless LibraryPlatformClient.configured?
        health.mark_not_configured!
        respond_with_flash(alert: "#{LibraryPlatformClient.display_name} is not configured. Enter connection details first.")
        return
      end

      if LibraryPlatformClient.test_connection
        health.check_succeeded!(message: "Connection successful")
        respond_with_flash(notice: "#{LibraryPlatformClient.display_name} connection successful!")
      else
        health.check_failed!(message: "Failed to connect to #{LibraryPlatformClient.display_name}")
        respond_with_flash(alert: "#{LibraryPlatformClient.display_name} connection failed.")
      end
    rescue LibraryPlatformClient::Error => e
      health&.check_failed!(message: e.message)
      respond_with_flash(alert: "#{LibraryPlatformClient.display_name} error: #{e.message}")
    end

    def sync_audiobookshelf_library
      unless LibraryPlatformClient.configured?
        redirect_to admin_settings_path, alert: "#{LibraryPlatformClient.display_name} is not configured. Enter connection details first."
        return
      end

      AudiobookshelfLibrarySyncJob.perform_later
      redirect_to admin_settings_path, notice: "#{LibraryPlatformClient.display_name} library sync started."
    end

    # FlareSolverr is not tracked in SystemHealth::SERVICES, so no SystemHealth sync here
    def test_flaresolverr
      unless FlaresolverrClient.configured?
        respond_with_flash(alert: "FlareSolverr URL is not configured.")
        return
      end

      if FlaresolverrClient.test_connection
        respond_with_flash(notice: "FlareSolverr connection successful!")
      else
        respond_with_flash(alert: "FlareSolverr connection failed.")
      end
    rescue FlaresolverrClient::Error => e
      respond_with_flash(alert: "FlareSolverr error: #{e.message}")
    end

    def test_hardcover
      health = SystemHealth.for_service("hardcover")

      unless HardcoverClient.configured?
        health.mark_not_configured!
        respond_with_flash(alert: "Hardcover is not configured. Enter API token first.")
        return
      end

      if HardcoverClient.test_connection
        MetadataProviderStatus.for_provider("hardcover").record_success!
        health.check_succeeded!(message: "Connection successful")
        respond_with_flash(notice: "Hardcover connection successful!")
      else
        health.check_failed!(message: "Failed to connect to Hardcover")
        respond_with_flash(alert: "Hardcover connection failed.")
      end
    rescue HardcoverClient::Error => e
      health&.check_failed!(message: e.message)
      respond_with_flash(alert: "Hardcover error: #{e.message}")
    end

    def test_google_books
      unless GoogleBooksClient.configured?
        respond_with_flash(alert: "Google Books is not enabled.")
        return
      end

      if GoogleBooksClient.test_connection
        MetadataProviderStatus.for_provider("google_books").record_success!
        respond_with_flash(notice: "Google Books connection successful!")
      else
        respond_with_flash(alert: "Google Books connection failed.")
      end
    rescue GoogleBooksClient::Error => e
      respond_with_flash(alert: "Google Books error: #{e.message}")
    end

    def test_open_library
      unless OpenLibraryClient.configured?
        respond_with_flash(alert: "Open Library is not enabled.")
        return
      end

      if OpenLibraryClient.test_connection
        MetadataProviderStatus.for_provider("openlibrary").record_success!
        respond_with_flash(notice: "Open Library connection successful!")
      else
        respond_with_flash(alert: "Open Library connection failed.")
      end
    rescue OpenLibraryClient::Error => e
      respond_with_flash(alert: "Open Library error: #{e.message}")
    end

    def test_zlibrary
      unless ZLibraryClient.configured?
        respond_with_flash(alert: "Z-Library is not configured. Enable it and enter your account credentials first.")
        return
      end

      if ZLibraryClient.test_connection
        respond_with_flash(notice: "Z-Library connection successful!")
      else
        respond_with_flash(alert: "Z-Library connection failed.")
      end
    end

    def test_librivox
      unless LibrivoxClient.configured?
        respond_with_flash(alert: "LibriVox is not enabled.")
        return
      end

      if LibrivoxClient.test_connection
        respond_with_flash(notice: "LibriVox connection successful!")
      else
        respond_with_flash(alert: "LibriVox connection failed.")
      end
    end

    def test_gutenberg
      unless GutenbergClient.configured?
        respond_with_flash(alert: "Project Gutenberg is not enabled.")
        return
      end

      if GutenbergClient.test_connection
        respond_with_flash(notice: "Project Gutenberg connection successful!")
      else
        respond_with_flash(alert: "Project Gutenberg connection failed.")
      end
    end

    def test_oidc
      unless SettingsService.get(:oidc_enabled, default: false)
        respond_with_flash(alert: "OIDC is not enabled. Enable it first.")
        return
      end

      issuer = SettingsService.get(:oidc_issuer).to_s.strip
      if issuer.blank?
        respond_with_flash(alert: "OIDC issuer URL is not configured.")
        return
      end

      # Try to fetch the OIDC discovery document
      discovery_url = "#{issuer.chomp('/')}/.well-known/openid-configuration"
      response = Faraday.get(discovery_url)

      if response.status == 200
        config = JSON.parse(response.body)
        if config["issuer"].present? && config["authorization_endpoint"].present?
          respond_with_flash(notice: "OIDC configuration valid! Provider: #{config['issuer']}")
        else
          respond_with_flash(alert: "OIDC discovery document is incomplete.")
        end
      else
        respond_with_flash(alert: "Failed to fetch OIDC discovery document (HTTP #{response.status}).")
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      respond_with_flash(alert: "Could not connect to OIDC provider: #{e.message}")
    rescue JSON::ParserError
      respond_with_flash(alert: "Invalid OIDC discovery document (not valid JSON).")
    rescue StandardError => e
      respond_with_flash(alert: "OIDC test error: #{e.message}")
    end

    def test_webhook
      payload = OutboundNotifications::WebhookDelivery.test_payload
      OutboundNotifications::WebhookDelivery.deliver!(
        event: payload[:event],
        title: payload[:title],
        message: payload[:message]
      )

      respond_with_flash(notice: "Webhook test sent successfully!")
    rescue OutboundNotifications::WebhookDelivery::ConfigurationError => e
      respond_with_flash(alert: e.message)
    rescue OutboundNotifications::WebhookDelivery::DeliveryError => e
      respond_with_flash(alert: e.message)
    end

    def test_discord
      OutboundNotifications::DiscordDelivery.deliver!(
        event: OutboundNotifications::DiscordDelivery::TEST_EVENT,
        title: "Shelfarr Test",
        message: "Test notification from Shelfarr"
      )

      respond_with_flash(notice: "Discord test sent successfully!")
    rescue OutboundNotifications::DiscordDelivery::ConfigurationError => e
      respond_with_flash(alert: e.message)
    rescue OutboundNotifications::DiscordDelivery::DeliveryError => e
      respond_with_flash(alert: e.message)
    end

    def test_telegram
      unless Integrations::Telegram::Configuration.configured?
        respond_with_flash(alert: "Telegram is not fully configured. Enable it and enter bot token and webhook secret first.")
        return
      end

      response = Integrations::Telegram::Client.get_me
      username = response.dig("result", "username") || "bot"
      respond_with_flash(notice: "Telegram connection successful: @#{username}")
    rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError => e
      respond_with_flash(alert: e.message)
    end

    def setup_telegram_webhook
      unless SettingsService.get(:telegram_enabled, default: false) && Integrations::Telegram::Configuration.bot_token.present? && Integrations::Telegram::Configuration.webhook_secret.present?
        respond_with_flash(alert: "Telegram is not fully configured. Enable it and enter bot token and webhook secret first.")
        return
      end

      SettingsService.set(:telegram_update_mode, "webhook")
      TelegramPollingJob.clear_schedule!
      Integrations::Telegram::Client.set_webhook!(url: integrations_telegram_webhook_url)
      respond_with_flash(notice: "Telegram webhook configured: #{integrations_telegram_webhook_url}")
    rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError => e
      respond_with_flash(alert: e.message)
    end

    def approve_telegram_chat
      code = params[:telegram_group_code].to_s.strip
      authorization = TelegramChatAuthorization.approve_code!(code, approved_by: Current.user)

      if authorization
        respond_with_flash(notice: "Telegram group authorized: #{authorization.chat_title.presence || authorization.chat_id}")
      else
        respond_with_flash(alert: "Telegram group code is invalid or expired.")
      end
    end

    def pause_telegram_chat
      authorization = TelegramChatAuthorization.find(params[:id])
      authorization.pause!

      respond_with_flash(notice: "Telegram group paused: #{telegram_chat_label(authorization)}")
    end

    def resume_telegram_chat
      authorization = TelegramChatAuthorization.find(params[:id])
      authorization.resume!

      respond_with_flash(notice: "Telegram group resumed: #{telegram_chat_label(authorization)}")
    end

    def delete_telegram_chat
      authorization = TelegramChatAuthorization.find(params[:id])
      label = telegram_chat_label(authorization)
      authorization.destroy!

      respond_with_flash(notice: "Telegram group removed: #{label}")
    end

    private

    def telegram_chat_label(authorization)
      authorization.chat_title.presence || authorization.chat_id
    end

    def respond_with_flash(notice: nil, alert: nil)
      respond_to do |format|
        format.html { redirect_to admin_settings_path, notice: notice, alert: alert }
        format.turbo_stream do
          flash.now[:notice] = notice if notice
          flash.now[:alert] = alert if alert
          render turbo_stream: turbo_stream.update("flash", partial: "shared/flash")
        end
      end
    end

    def load_telegram_chat_authorizations
      @telegram_chat_authorizations = TelegramChatAuthorization.order(approved_at: :desc, updated_at: :desc)
    end

    def run_service_health_check(service_name)
      HealthCheckJob.perform_later(service: service_name)
    rescue => e
      Rails.logger.warn "[SettingsController] Failed to enqueue health check for #{service_name}: #{e.message}"
    end

    def run_service_health_check_now(service_name)
      HealthCheckJob.perform_now(service: service_name)
    rescue => e
      Rails.logger.warn "[SettingsController] Failed to run health check for #{service_name}: #{e.message}"
    end

    def handle_settings_side_effects(changed_keys)
      return if changed_keys.blank?

      if changed_keys.any? { |k| library_platform_setting_key?(k) }
        LibraryPlatformClient.reset_connections!
        AudiobookshelfLibrarySyncJob.perform_later if LibraryPlatformClient.configured?
        run_service_health_check("audiobookshelf")
      end
      if changed_keys.any? { |k| indexer_setting_key?(k) }
        IndexerClient.reset_all_connections!
        run_service_health_check("indexer")
      end
      if changed_keys.any? { |k| k == "flaresolverr_url" }
        FlaresolverrClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("anna_archive") }
        AnnaArchiveClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("zlibrary") }
        ZLibraryClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("gutenberg") }
        GutenbergClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("librivox") }
        LibrivoxClient.reset_connection!
      end
      if changed_keys.any? { |k| metadata_provider_setting?(k) }
        MetadataProviderStatus.clear_after_credential_change_for_settings!(changed_keys)
      end
      if changed_keys.any? { |k| k.start_with?("hardcover") }
        HardcoverClient.reset_connection!
        run_service_health_check("hardcover")
      end
      if changed_keys.any? { |k| k.start_with?("google_books") }
        GoogleBooksClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("open_library") }
        OpenLibraryClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("telegram") }
        sync_telegram_transport
      end
      if changed_keys.any? { |k| k.start_with?("audiobook_output_path") || k.start_with?("ebook_output_path") }
        run_service_health_check_now("output_paths")
      end
    end

    PATH_TEMPLATE_SETTINGS = %w[audiobook_path_template ebook_path_template].freeze
    FILENAME_TEMPLATE_SETTINGS = %w[audiobook_filename_template ebook_filename_template].freeze

    def validate_path_template!(key, value)
      error = validate_path_template(key, value)
      raise ArgumentError, error if error
    end

    def validate_path_template(key, value)
      mode =
        if PATH_TEMPLATE_SETTINGS.include?(key.to_s)
          :path
        elsif FILENAME_TEMPLATE_SETTINGS.include?(key.to_s)
          :filename
        end

      return nil unless mode

      valid, error = PathTemplateService.validate_template(value, mode: mode)
      valid ? nil : error
    end

    def fetch_audiobookshelf_libraries
      return [] unless LibraryPlatformClient.configured?

      LibraryPlatformClient.libraries
    rescue LibraryPlatformClient::Error => e
      Rails.logger.warn "[SettingsController] Failed to fetch #{LibraryPlatformClient.display_name} libraries: #{e.message}"
      []
    end

    def sync_telegram_transport
      if Integrations::Telegram::Configuration.polling?
        TelegramPollingJob.clear_schedule!
        if Integrations::Telegram::Configuration.configured?
          begin
            Integrations::Telegram::Client.delete_webhook!(drop_pending_updates: false)
          rescue => e
            Rails.logger.warn "[SettingsController] Failed to clear Telegram webhook for polling mode: #{e.message}"
          end
          TelegramPollingJob.ensure_running!
        end
      else
        TelegramPollingJob.clear_schedule!
      end
    end

    def load_audiobookshelf_cache_summary
      active_library_items = LibraryItem.for_active_platform
      @audiobookshelf_library_items = active_library_items.by_synced_at_desc.limit(50)
      @audiobookshelf_library_items_count = active_library_items.count
      @audiobookshelf_available_library_items_count = LibraryItem.available_for_matching.count
      @audiobookshelf_missing_library_items_count = active_library_items.where(missing: true).count
      @audiobookshelf_library_items_last_synced_at = @audiobookshelf_library_items.maximum(:synced_at)
    end

    def ensure_settings_seeded
      SettingsService.seed_defaults!
    end

    def indexer_setting_key?(key)
      key.start_with?("indexer_") || key.start_with?("prowlarr") || key.start_with?("jackett") || key.start_with?("newznab")
    end

    def metadata_provider_setting?(key)
      MetadataProviderStatus.provider_for_setting(key).present?
    end

    def library_platform_setting_key?(key)
      key.start_with?("audiobookshelf") || key.start_with?("bookorbit") || key == "library_platform"
    end

    def preserve_blank_secret?(key, value)
      secret_setting_key?(key) && value.blank? && SettingsService.get(key).present?
    end

    def secret_setting_key?(key)
      key = key.to_s
      key == "discord_webhook_url" || key.include?("password") || key.include?("api_key") || key.include?("token") || key.include?("secret")
    end
  end
end
