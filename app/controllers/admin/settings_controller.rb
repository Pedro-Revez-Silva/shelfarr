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

      if errors.any?
        redirect_to admin_settings_path, alert: errors.join(". ")
      else
        redirect_to admin_settings_path, notice: "Settings updated successfully."
      end
    rescue ArgumentError => e
      redirect_to admin_settings_path, alert: e.message
    end

    def test_prowlarr
      unless ProwlarrClient.configured?
        redirect_to admin_settings_path, alert: "Prowlarr is not configured. Enter URL and API key first."
        return
      end

      if ProwlarrClient.test_connection
        redirect_to admin_settings_path, notice: "Prowlarr connection successful!"
      else
        redirect_to admin_settings_path, alert: "Prowlarr connection failed."
      end
    rescue ProwlarrClient::Error => e
      redirect_to admin_settings_path, alert: "Prowlarr error: #{e.message}"
    end

    def test_audiobookshelf
      unless AudiobookshelfClient.configured?
        redirect_to admin_settings_path, alert: "Audiobookshelf is not configured. Enter URL and API key first."
        return
      end

      if AudiobookshelfClient.test_connection
        redirect_to admin_settings_path, notice: "Audiobookshelf connection successful!"
      else
        redirect_to admin_settings_path, alert: "Audiobookshelf connection failed."
      end
    rescue AudiobookshelfClient::Error => e
      redirect_to admin_settings_path, alert: "Audiobookshelf error: #{e.message}"
    end

    def test_oidc
      unless SettingsService.get(:oidc_enabled, default: false)
        redirect_to admin_settings_path, alert: "OIDC is not enabled. Enable it first."
        return
      end

      issuer = SettingsService.get(:oidc_issuer).to_s.strip
      if issuer.blank?
        redirect_to admin_settings_path, alert: "OIDC issuer URL is not configured."
        return
      end

      # Try to fetch the OIDC discovery document
      discovery_url = "#{issuer.chomp('/')}/.well-known/openid-configuration"
      response = Faraday.get(discovery_url)

      if response.status == 200
        config = JSON.parse(response.body)
        if config["issuer"].present? && config["authorization_endpoint"].present?
          redirect_to admin_settings_path, notice: "OIDC configuration valid! Provider: #{config['issuer']}"
        else
          redirect_to admin_settings_path, alert: "OIDC discovery document is incomplete."
        end
      else
        redirect_to admin_settings_path, alert: "Failed to fetch OIDC discovery document (HTTP #{response.status})."
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      redirect_to admin_settings_path, alert: "Could not connect to OIDC provider: #{e.message}"
    rescue JSON::ParserError
      redirect_to admin_settings_path, alert: "Invalid OIDC discovery document (not valid JSON)."
    rescue StandardError => e
      redirect_to admin_settings_path, alert: "OIDC test error: #{e.message}"
    end

    private

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
