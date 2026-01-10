module Admin
  class SettingsController < BaseController
    before_action :ensure_settings_seeded, only: :index

    def index
      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries
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

      # Reset cached connections when relevant settings change
      AudiobookshelfClient.reset_connection! if params[:settings]&.keys&.any? { |k| k.to_s.start_with?("audiobookshelf") }
      ProwlarrClient.reset_connection! if params[:settings]&.keys&.any? { |k| k.to_s.start_with?("prowlarr") }

      @settings_by_category = SettingsService.all_by_category
      @audiobookshelf_libraries = fetch_audiobookshelf_libraries

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
      unless ProwlarrClient.configured?
        respond_with_flash(alert: "Prowlarr is not configured. Enter URL and API key first.")
        return
      end

      if ProwlarrClient.test_connection
        respond_with_flash(notice: "Prowlarr connection successful!")
      else
        respond_with_flash(alert: "Prowlarr connection failed.")
      end
    rescue ProwlarrClient::Error => e
      respond_with_flash(alert: "Prowlarr error: #{e.message}")
    end

    def test_audiobookshelf
      unless AudiobookshelfClient.configured?
        respond_with_flash(alert: "Audiobookshelf is not configured. Enter URL and API key first.")
        return
      end

      if AudiobookshelfClient.test_connection
        respond_with_flash(notice: "Audiobookshelf connection successful!")
      else
        respond_with_flash(alert: "Audiobookshelf connection failed.")
      end
    rescue AudiobookshelfClient::Error => e
      respond_with_flash(alert: "Audiobookshelf error: #{e.message}")
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

    def ensure_settings_seeded
      SettingsService.seed_defaults!
    end
  end
end
