# frozen_string_literal: true

class SetupWizard
  class Form
    ATTRIBUTES = %i[
      previous_step libraries library_error url api_key username password category saved_secret saved_qbittorrent_api_key
      audiobook_output_path ebook_output_path download_local_path download_remote_path immediate_search auto_select
      auto_select_threshold auto_select_min_seeders warnings audiobook_library_id ebook_library_id
    ].freeze

    attr_reader :step, *ATTRIBUTES

    def initialize(step:, submitted: nil, suggest_libraries: false)
      @step = SetupWizard.normalize_step(step)
      @submitted = submitted.presence && (submitted.respond_to?(:to_unsafe_h) ? submitted.to_unsafe_h : submitted.to_h.with_indifferent_access)
      @suggest_libraries = suggest_libraries.present?
      build
    end

    def connected_to_library_platform?
      libraries.present? && library_error.blank?
    end

    private

    def build
      @previous_step = SetupWizard.previous_step(step)
      @libraries = []
      @library_error = nil
      client = SetupWizard.qbittorrent_client

      @url = text_field(:url, saved_url(client))
      @api_key = submitted_value(:api_key)
      @username = text_field(:username, client&.username.to_s)
      @password = submitted_value(:password)
      @category = text_field(:category, client&.category.to_s)
      @saved_secret = saved_secret?(client)
      @saved_qbittorrent_api_key = client&.api_key.present?
      @audiobook_output_path = text_field(:audiobook_output_path, SettingsService.get(:audiobook_output_path))
      @ebook_output_path = text_field(:ebook_output_path, SettingsService.get(:ebook_output_path))
      @download_local_path = text_field(:download_local_path, SettingsService.get(:download_local_path))
      @download_remote_path = text_field(:download_remote_path, step == "folders" ? saved_remote_path : SettingsService.get(:download_remote_path).to_s)
      @immediate_search = boolean_field(:immediate_search_enabled, SettingsService.get(:immediate_search_enabled) != false)
      @auto_select = boolean_field(:auto_select_enabled, SettingsService.get(:auto_select_enabled) == true)
      @auto_select_threshold = SettingsService.get(:auto_select_confidence_threshold).to_i
      @auto_select_min_seeders = SettingsService.get(:auto_select_min_seeders).to_i
      @warnings = step_warnings

      return unless step == "audiobookshelf"
      return unless SettingsService.configured?(:audiobookshelf_url) && SettingsService.configured?(:audiobookshelf_api_key)

      @libraries, @library_error = SetupWizard.library_choices
      @audiobook_library_id = text_field(:audiobook_library_id, saved_or_suggested_library(:audiobookshelf_audiobook_library_id, @audiobook_output_path))
      @ebook_library_id = text_field(:ebook_library_id, saved_or_suggested_library(:audiobookshelf_ebook_library_id, @ebook_output_path))
    end

    def step_warnings
      case step
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
      case step
      when "prowlarr" then SettingsService.configured?(:prowlarr_api_key)
      when "qbittorrent" then client&.password.present?
      when "audiobookshelf" then SettingsService.configured?(:audiobookshelf_api_key)
      else false
      end
    end

    def saved_or_suggested_library(key, output_path)
      saved = SettingsService.get(key).to_s
      return saved if saved.present? || !@suggest_libraries

      SetupWizard.suggested_library_id(@libraries, output_path).to_s
    end

    def saved_url(client)
      case step
      when "prowlarr" then SettingsService.get(:prowlarr_url)
      when "qbittorrent" then client&.url.to_s
      when "audiobookshelf" then SettingsService.get(:audiobookshelf_url)
      else ""
      end
    end

    def saved_remote_path
      SettingsService.get(:download_remote_path).presence || SetupWizard.suggested_remote_path(@download_local_path).to_s
    end

    def submitted_value(key)
      @submitted&.dig(key).to_s
    end

    def text_field(key, saved)
      return saved if @submitted.blank? || !@submitted.key?(key)

      @submitted[key]
    end

    def boolean_field(key, saved)
      return saved if @submitted.blank? || !@submitted.key?(key)

      ActiveModel::Type::Boolean.new.cast(@submitted[key])
    end
  end
end
