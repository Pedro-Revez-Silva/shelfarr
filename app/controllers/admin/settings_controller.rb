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
