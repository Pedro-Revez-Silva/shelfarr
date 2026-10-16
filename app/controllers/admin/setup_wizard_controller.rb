# frozen_string_literal: true

module Admin
  class SetupWizardController < BaseController
    def show
      @step = SetupWizard.normalize_step(params[:step])
      prepare_step
    end

    def update
      @step = SetupWizard.normalize_step(params[:step])
      result = SetupWizard.save(@step, wizard_params)
      if result.success?
        redirect_after_save(result)
      else
        @error = result.error
        prepare_step
        render :show, status: :unprocessable_entity
      end
    end

    def skip
      step = SetupWizard.normalize_step(params[:step])
      if params[:exit].present? || step == "search"
        SetupWizard.complete!
        redirect_to root_path, notice: "Setup skipped. You can run it again from Setup in the header."
      else
        redirect_to admin_setup_wizard_path(step: SetupWizard.next_step(step))
      end
    end

    def restart
      SetupWizard.restart!
      redirect_to admin_setup_wizard_path
    end

    private

    def redirect_after_save(result)
      if result.stay?
        # Preselect libraries only right after connecting, so a saved "Not now" stays.
        redirect_to admin_setup_wizard_path(step: @step), notice: result.notice, flash: { suggest_libraries: true }
      elsif @step == "search"
        redirect_to root_path, notice: "Setup complete."
      else
        options = { notice: result.notice }
        options[:alert] = result.alert if result.alert.present?
        redirect_to admin_setup_wizard_path(step: SetupWizard.next_step(@step)), **options
      end
    end

    def prepare_step
      @previous_step = SetupWizard.previous_step(@step)
      @libraries = []
      @library_error = nil
      client = SetupWizard.qbittorrent_client

      @url = text_field(:url, saved_url(client))
      @api_key = params.dig(:wizard, :api_key).to_s
      @username = text_field(:username, client&.username.to_s)
      @password = params.dig(:wizard, :password).to_s
      @category = text_field(:category, client&.category.to_s)
      @saved_secret = saved_secret?(client)
      @saved_qbittorrent_api_key = client&.api_key.present?
      @audiobook_output_path = text_field(:audiobook_output_path, SettingsService.get(:audiobook_output_path))
      @ebook_output_path = text_field(:ebook_output_path, SettingsService.get(:ebook_output_path))
      @download_local_path = text_field(:download_local_path, SettingsService.get(:download_local_path))
      @download_remote_path = text_field(:download_remote_path, @step == "folders" ? saved_remote_path : SettingsService.get(:download_remote_path).to_s)
      @immediate_search = boolean_field(:immediate_search_enabled, SettingsService.get(:immediate_search_enabled) != false)
      @auto_select = boolean_field(:auto_select_enabled, SettingsService.get(:auto_select_enabled) == true)
      @auto_select_threshold = SettingsService.get(:auto_select_confidence_threshold).to_i
      @auto_select_min_seeders = SettingsService.get(:auto_select_min_seeders).to_i
      @warnings = step_warnings

      return unless @step == "audiobookshelf"
      return unless SettingsService.configured?(:audiobookshelf_url) && SettingsService.configured?(:audiobookshelf_api_key)

      @libraries, @library_error = SetupWizard.library_choices
      @audiobook_library_id = text_field(:audiobook_library_id, saved_or_suggested_library(:audiobookshelf_audiobook_library_id, @audiobook_output_path))
      @ebook_library_id = text_field(:ebook_library_id, saved_or_suggested_library(:audiobookshelf_ebook_library_id, @ebook_output_path))
    end

    # Folders checks the paths on its form, including a suggested remote path, before they are saved.
    def step_warnings
      case @step
      when "folders"
        SetupWizard.path_warnings(
          download_local_path: @download_local_path,
          download_remote_path: @download_remote_path,
          audiobook_output_path: @audiobook_output_path,
          ebook_output_path: @ebook_output_path
        )
      when "search" then SetupWizard.path_warnings
      else []
      end
    end

    def saved_secret?(client)
      case @step
      when "prowlarr" then SettingsService.configured?(:prowlarr_api_key)
      when "qbittorrent" then client&.password.present?
      when "audiobookshelf" then SettingsService.configured?(:audiobookshelf_api_key)
      else false
      end
    end

    def saved_or_suggested_library(key, output_path)
      saved = SettingsService.get(key).to_s
      return saved if saved.present? || !flash[:suggest_libraries]

      SetupWizard.suggested_library_id(@libraries, output_path).to_s
    end

    def saved_url(client)
      case @step
      when "prowlarr" then SettingsService.get(:prowlarr_url)
      when "qbittorrent" then client&.url.to_s
      when "audiobookshelf" then SettingsService.get(:audiobookshelf_url)
      else ""
      end
    end

    def saved_remote_path
      SettingsService.get(:download_remote_path).presence || SetupWizard.suggested_remote_path(@download_local_path).to_s
    end

    def text_field(key, saved)
      wizard = params[:wizard]
      return saved if wizard.blank? || !wizard.key?(key)

      wizard[key]
    end

    def boolean_field(key, saved)
      wizard = params[:wizard]
      return saved if wizard.blank? || !wizard.key?(key)

      ActiveModel::Type::Boolean.new.cast(wizard[key])
    end

    def wizard_params
      params.fetch(:wizard, ActionController::Parameters.new).permit(
        :url, :api_key, :username, :password, :category, :phase,
        :audiobook_output_path, :ebook_output_path, :download_local_path, :download_remote_path,
        :audiobook_library_id, :ebook_library_id,
        :immediate_search_enabled, :auto_select_enabled
      ).to_h
    end
  end
end
