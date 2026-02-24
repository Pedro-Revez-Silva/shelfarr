module Admin
  class SettingsController < BaseController
    before_action :ensure_settings_seeded, only: :index

    def index
      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
      load_audiobookshelf_cache_summary
    end

    def update
      key = params[:id]
      value = params[:setting][:value]

      validate_path_template!(key, value)
      SettingsService.set(key, value)

      respond_to do |format|
        format.html { redirect_to admin_settings_path, notice: "Setting updated." }
        format.turbo_stream
      end
    rescue ArgumentError => e
      redirect_to admin_settings_path, alert: e.message
    end

    def bulk_update
      errors = []

      params[:settings]&.each do |key, value|
        error = validate_path_template(key, value)
        if error
          errors << "#{key.to_s.titleize}: #{error}"
        else
          SettingsService.set(key, value)
        end
      end

      # Reset cached connections and trigger health checks when relevant settings change
      changed_keys = params[:settings]&.keys&.map(&:to_s) || []

      if changed_keys.any? { |k| k.start_with?("audiobookshelf") }
        AudiobookshelfClient.reset_connection!
        AudiobookshelfLibrarySyncJob.perform_later if AudiobookshelfClient.configured?
        run_service_health_check("audiobookshelf")
      end
      if changed_keys.any? { |k| k.start_with?("prowlarr") }
        ProwlarrClient.reset_connection!
        run_service_health_check("prowlarr")
      end
      if changed_keys.any? { |k| k == "flaresolverr_url" }
        FlaresolverrClient.reset_connection!
      end
      if changed_keys.any? { |k| k.start_with?("hardcover") }
        HardcoverClient.reset_connection!
        run_service_health_check("hardcover")
      end
      if changed_keys.any? { |k| k.start_with?("audiobook_output_path") || k.start_with?("ebook_output_path") }
        run_service_health_check_now("output_paths")
      end

      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
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

    def test_prowlarr
      health = SystemHealth.for_service("prowlarr")

      unless ProwlarrClient.configured?
        health.mark_not_configured!
        respond_with_flash(alert: "Prowlarr is not configured. Enter URL and API key first.")
        return
      end

      if ProwlarrClient.test_connection
        health.check_succeeded!(message: "Connection successful")
        respond_with_flash(notice: "Prowlarr connection successful!")
      else
        health.check_failed!(message: "Failed to connect to Prowlarr")
        respond_with_flash(alert: "Prowlarr connection failed.")
      end
    rescue ProwlarrClient::Error => e
      health&.check_failed!(message: e.message)
      respond_with_flash(alert: "Prowlarr error: #{e.message}")
    end

    def test_audiobookshelf
      health = SystemHealth.for_service("audiobookshelf")

      unless AudiobookshelfClient.configured?
        health.mark_not_configured!
        respond_with_flash(alert: "Audiobookshelf is not configured. Enter URL and API key first.")
        return
      end

      if AudiobookshelfClient.test_connection
        health.check_succeeded!(message: "Connection successful")
        respond_with_flash(notice: "Audiobookshelf connection successful!")
      else
        health.check_failed!(message: "Failed to connect to Audiobookshelf")
        respond_with_flash(alert: "Audiobookshelf connection failed.")
      end
    rescue AudiobookshelfClient::Error => e
      health&.check_failed!(message: e.message)
      respond_with_flash(alert: "Audiobookshelf error: #{e.message}")
    end

    def sync_audiobookshelf_library
      unless AudiobookshelfClient.configured?
        redirect_to admin_settings_path, alert: "Audiobookshelf is not configured. Enter URL and API key first."
        return
      end

      AudiobookshelfLibrarySyncJob.perform_later
      redirect_to admin_settings_path, notice: "Audiobookshelf library sync started."
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

    private

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

    PATH_TEMPLATE_SETTINGS = %w[audiobook_path_template ebook_path_template].freeze

    def validate_path_template!(key, value)
      error = validate_path_template(key, value)
      raise ArgumentError, error if error
    end

    def validate_path_template(key, value)
      return nil unless PATH_TEMPLATE_SETTINGS.include?(key.to_s)

      valid, error = PathTemplateService.validate_template(value)
      valid ? nil : error
    end

    def fetch_audiobookshelf_libraries
      return [] unless AudiobookshelfClient.configured?

      AudiobookshelfClient.libraries
    rescue AudiobookshelfClient::Error => e
      Rails.logger.warn "[SettingsController] Failed to fetch Audiobookshelf libraries: #{e.message}"
      []
    end

    def load_audiobookshelf_cache_summary
      @audiobookshelf_library_items = LibraryItem.by_synced_at_desc.limit(50)
      @audiobookshelf_library_items_count = LibraryItem.count
      @audiobookshelf_library_items_last_synced_at = @audiobookshelf_library_items.maximum(:synced_at)
    end

    def ensure_settings_seeded
      SettingsService.seed_defaults!
    end
  end
end
