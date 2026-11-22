module Admin
  class SettingsController < BaseController
    before_action :ensure_settings_seeded, only: :index

    def index
      @settings_by_category = SettingsService.all_by_category
      libraries = ServerSettings::LibraryInventory.platform_libraries
      @audiobookshelf_libraries = case libraries
      when RemoteResult::Failed
        []
      else
        libraries
      end
      load_telegram_chat_authorizations
      load_audiobookshelf_cache_summary
    end

    def update
      key = params[:id]

      if SettingsService.env_managed?(key)
        redirect_to admin_settings_path, alert: "#{SettingsService.label_for(key)} is managed by the environment and cannot be changed here."
        return
      end

      value = ServerSettings::Change.normalize(key, params[:setting][:value])

      unless ServerSettings::Change.preserve_blank_secret?(key, value)
        validate_setting_value!(key, value)
        SettingsService.set(key, value)
        ServerSettings::FollowUp.call([ key.to_s ])
      end

      respond_to do |format|
        format.html { redirect_to admin_settings_path, notice: "Setting updated." }
        format.turbo_stream
      end
    rescue ArgumentError => e
      redirect_to admin_settings_path, alert: e.message
    end

    def bulk_update
      validate_submitted_setting_keys!
      validate_autosave_setting_keys!
      validate_manual_setting_keys!

      candidates = []
      params[:settings]&.each do |key, value|
        next if SettingsService.env_managed?(key)
        # A named list is the fields this autosave may write. An empty list is not a manifest.
        next if autosave? && autosave_key_list.any? && !autosave_key_list.include?(key.to_s)
        next if autosave? && SettingsService.manual_save_setting_key?(key)
        next if ServerSettings::Change.unchanged_secret?(key, value)
        next if skip_unlisted_manual_setting?(key)

        candidates << [ key, value ]
      end

      result = setting_change.apply(candidates)
      errors = result.rejections.map(&:text)
      side_effect_error = result.follow_up_error

      respond_to do |format|
        if errors.any?
          format.html { redirect_to admin_settings_path, alert: errors.join(". ") }
          format.turbo_stream do
            flash.now[:alert] = errors.join(". ")
            render turbo_stream: turbo_stream.update("flash", partial: "shared/flash"), status: :unprocessable_entity
          end
        elsif side_effect_error
          message = "Settings saved, but a follow-up action failed: #{side_effect_error.message}"
          format.html { redirect_to admin_settings_path, alert: message }
          format.turbo_stream do
            flash.now[:alert] = message
            render turbo_stream: turbo_stream.update("flash", partial: "shared/flash")
          end
        else
          format.html { redirect_to admin_settings_path, notice: "Settings updated successfully." }
          format.turbo_stream do
            if autosave?
              head :no_content
            else
              flash.now[:notice] = "Settings updated successfully."
              render turbo_stream: turbo_stream.update("flash", partial: "shared/flash")
            end
          end
        end
      end
    rescue ArgumentError => e
      respond_to do |format|
        format.html { redirect_to admin_settings_path, alert: e.message }
        format.turbo_stream do
          flash.now[:alert] = e.message
          render turbo_stream: turbo_stream.update("flash", partial: "shared/flash"), status: :unprocessable_entity
        end
      end
    end

    ServerSettings::Probe::NAMES.excluding("telegram_webhook").each do |name|
      define_method("test_#{name}") { run_probe(name) }
    end

    def test_prowlarr
      run_probe("indexer")
    end

    def sync_audiobookshelf_library
      unless ServerSettings::LibraryInventory.start_sync
        redirect_to admin_settings_path, alert: "#{LibraryPlatformClient.display_name} is not configured. Enter connection details first."
        return
      end

      redirect_to admin_settings_path, notice: "#{LibraryPlatformClient.display_name} library sync started."
    end

    def setup_telegram_webhook
      run_probe("telegram_webhook")
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

    def autosave?
      params[:autosave] == "true"
    end

    def autosave_key_list
      @autosave_key_list ||= params[:autosave_keys].to_s.split(",").reject(&:blank?)
    end

    def manual_setting_manifest?
      params.key?(:manual_keys)
    end

    def manual_setting_keys
      @manual_setting_keys ||= params[:manual_keys].to_s.split(",").reject(&:blank?)
    end

    def validate_submitted_setting_keys!
      settings = params[:settings]
      return if settings.nil?
      raise ArgumentError, "Settings must be submitted as key-value pairs" unless settings.is_a?(ActionController::Parameters)

      unknown_key = settings.keys.find do |key|
        !SettingsService::DEFINITIONS.key?(key.to_sym)
      end
      raise ArgumentError, "Unknown setting: #{unknown_key}" if unknown_key
    end

    def validate_autosave_setting_keys!
      return unless autosave?
      return if autosave_key_list.empty?

      settings = params[:settings]
      invalid = settings.nil? || autosave_key_list.any? do |key|
        !SettingsService::DEFINITIONS.key?(key.to_sym) || !settings.key?(key)
      end
      raise ArgumentError, "Invalid autosave setting manifest" if invalid
    end

    def validate_manual_setting_keys!
      return unless manual_setting_manifest?

      settings = params[:settings] || ActionController::Parameters.new
      invalid = manual_setting_keys.any? do |key|
        !SettingsService.manual_save_setting_key?(key) || !settings.key?(key)
      end
      raise ArgumentError, "Invalid manual setting manifest" if invalid
    end

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

    def run_probe(name)
      outcome = ServerSettings::Probe.new(posted: params[:settings] || {}, telegram_webhook_url: integrations_telegram_webhook_url).call(name)
      respond_with_flash(outcome.tone => outcome.message)
    end

    def setting_change
      @setting_change ||= ServerSettings::Change.new(lookup: method(:setting_value_for_validation))
    end

    def validate_setting_value!(key, value)
      error = setting_change.error_for(key, value)
      raise ArgumentError, "#{SettingsService.label_for(key)}: #{error}" if error
    end

    def setting_value_for_validation(key)
      settings = params[:settings]
      listed = autosave_key_list.empty? || autosave_key_list.include?(key.to_s)
      submitted = settings&.key?(key.to_s) && (!autosave? || listed)
      submitted ? settings[key.to_s] : SettingsService.get(key)
    end

    def load_audiobookshelf_cache_summary
      inventory = ServerSettings::LibraryInventory.new
      @audiobookshelf_library_items = inventory.recent_items
      @audiobookshelf_library_items_count = inventory.count
      @audiobookshelf_available_library_items_count = inventory.available_count
      @audiobookshelf_missing_library_items_count = inventory.missing_count
      @audiobookshelf_library_items_last_synced_at = inventory.last_synced_at
    end

    def ensure_settings_seeded
      SettingsService.seed_defaults!
    end

    def skip_unlisted_manual_setting?(key)
      return false unless manual_setting_manifest?
      return false unless SettingsService.manual_save_setting_key?(key)
      return false if SettingsService.secret_setting_key?(key)

      !manual_setting_keys.include?(key.to_s)
    end
  end
end
