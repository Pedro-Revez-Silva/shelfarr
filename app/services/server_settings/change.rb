# frozen_string_literal: true

module ServerSettings
  class Change
    Rejection = Data.define(:key, :message) do
      def text
        "#{SettingsService.label_for(key)}: #{message}"
      end
    end

    Result = Data.define(:rejections, :changed_keys, :follow_up_error) do
      def rejected?
        rejections.any?
      end
    end

    PATH_TEMPLATE_SETTINGS = %w[audiobook_path_template ebook_path_template].freeze
    FILENAME_TEMPLATE_SETTINGS = %w[audiobook_filename_template ebook_filename_template].freeze
    INDEXER_URL_PROVIDERS = {
      "prowlarr_url" => IndexerClients::Prowlarr,
      "jackett_url" => IndexerClients::Jackett,
      "newznab_url" => IndexerClients::Newznab
    }.freeze

    class << self
      def unchanged_secret?(key, value)
        return false unless SettingsService.secret_setting_key?(key)

        value.blank? || value.to_s == SettingsService.get(key).to_s
      end

      def preserve_blank_secret?(key, value)
        SettingsService.secret_setting_key?(key) && value.blank? && SettingsService.get(key).present?
      end

      def normalize(key, value)
        return SettingsService.canonical_file_size_setting(value) if SettingsService.file_size_limit_key?(key)

        case key.to_s
        when "ebooks_com_country_code"
          value.to_s.strip.upcase
        when /\Aaudiobookshelf_.*_scan_library_ids\z/
          Array(value).flat_map { |v| v.to_s.split(",").map(&:strip) }.reject(&:blank?).join(",")
        else
          INDEXER_URL_PROVIDERS.key?(key.to_s) ? value.to_s.strip : value
        end
      end
    end

    def initialize(lookup:)
      @lookup = lookup
    end

    def apply(candidates)
      rejections = []
      entries = []
      candidates.each do |key, value|
        value = self.class.normalize(key, value)
        error = error_for(key, value)
        next if error.nil? && !stored_setting_changed?(key, value)

        if error
          rejections << Rejection.new(key: key.to_s, message: error)
        else
          entries << [ key, value ]
        end
      end
      return Result.new(rejections: rejections, changed_keys: [], follow_up_error: nil) if rejections.any?

      Setting.transaction { entries.each { |key, value| SettingsService.set(key, value) } }
      changed_keys = entries.map { |key, _| key.to_s }
      Result.new(rejections: [], changed_keys: changed_keys, follow_up_error: FollowUp.call(changed_keys))
    end

    def error_for(key, value)
      type_error(key, value) ||
        completed_download_import_mode_error(key, value) ||
        library_import_mode_error(key, value) ||
        default_request_format_error(key, value) ||
        path_template_error(key, value) ||
        indexer_url_error(key, value) ||
        ebooks_com_error(key, value) ||
        auto_select_confidence_threshold_error(key, value) ||
        file_size_error(key, value)
    end

    private

    attr_reader :lookup

    def auto_select_confidence_threshold_error(key, value)
      return nil unless key.to_s == "auto_select_confidence_threshold"

      parsed = Integer(value.to_s, 10, exception: false)
      return nil if parsed&.between?(0, 100)

      "must be an integer from 0 to 100"
    end

    def file_size_error(key, value)
      return nil unless SettingsService.file_size_limit_key?(key)

      normalized = SettingsService.canonical_file_size_setting(value)
      if normalized.present? && SettingsService.parse_file_size_bytes(normalized).nil?
        return "must be a file size such as 200 KB, 50 MB, or 1.5 GB. A number alone means megabytes."
      end

      pair = SettingsService::FILE_SIZE_LIMIT_PAIRS.find { |min_key, max_key| [ min_key, max_key ].include?(key.to_sym) }
      return nil unless pair

      min_key, max_key = pair
      min_bytes = SettingsService.parse_file_size_bytes(file_size_text(min_key, key, normalized))
      max_bytes = SettingsService.parse_file_size_bytes(file_size_text(max_key, key, normalized))
      return nil if min_bytes.nil? || max_bytes.nil? || min_bytes <= max_bytes

      if key.to_sym == min_key
        "must be less than or equal to #{SettingsService.label_for(max_key)}"
      else
        "must be greater than or equal to #{SettingsService.label_for(min_key)}"
      end
    end

    def file_size_text(limit_key, current_key, current_value)
      raw = limit_key.to_sym == current_key.to_sym ? current_value : lookup.call(limit_key)
      SettingsService.canonical_file_size_setting(raw)
    end

    def type_error(key, value)
      type = SettingsService::DEFINITIONS.dig(key.to_sym, :type)
      case type
      when "boolean"
        return nil if [ true, false, 1, 0, "1", "0", "true", "false" ].include?(value)

        "must be true or false"
      when "integer"
        "must be an integer" unless Integer(value.to_s, 10, exception: false)
      when "string"
        "must be a scalar value" if collection?(value) || value.is_a?(Array)
      when "json"
        "must be a scalar or list" if collection?(value)
      end
    end

    def collection?(value)
      value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
    end

    def completed_download_import_mode_error(key, value)
      return nil unless key.to_s == "completed_download_import_mode"
      return nil if SettingsService::COMPLETED_DOWNLOAD_IMPORT_MODES.include?(value.to_s)

      "must be one of: #{SettingsService::COMPLETED_DOWNLOAD_IMPORT_MODES.join(', ')}"
    end

    def library_import_mode_error(key, value)
      return nil unless SettingsService::LIBRARY_IMPORT_PERMISSION_KEYS.include?(key.to_sym)

      text = value.to_s.strip
      return nil if text.empty? || SettingsService.library_import_mode_acceptable?(key, text)

      SettingsService.library_import_mode_requirement(key)
    end

    def default_request_format_error(key, value)
      return nil unless key.to_s == "default_request_format"
      return nil if SettingsService::DEFAULT_REQUEST_FORMATS.include?(value.to_s)

      "must be one of: #{SettingsService::DEFAULT_REQUEST_FORMATS.join(', ')}"
    end

    def path_template_error(key, value)
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

    def indexer_url_error(key, value)
      provider = INDEXER_URL_PROVIDERS[key.to_s]
      return nil unless provider
      return nil if value.blank?

      provider.validate_url!(value)
      nil
    rescue IndexerClients::Base::InvalidUrlError => e
      indexer_url_message(e)
    end

    def ebooks_com_error(key, value)
      case key.to_s
      when "ebooks_com_enabled"
        return nil unless ActiveModel::Type::Boolean.new.cast(value)
        return nil if EbooksComClient.valid_country_code?(lookup.call(:ebooks_com_country_code).to_s.strip)

        "requires a valid ISO 3166-1 Buyer Country Code"
      when "ebooks_com_country_code"
        country_code = value.to_s.strip
        return nil if country_code.blank? && !ActiveModel::Type::Boolean.new.cast(lookup.call(:ebooks_com_enabled))
        return nil if EbooksComClient.valid_country_code?(country_code)

        "must be a valid ISO 3166-1 country code (for example US, GB, or PT)"
      when "ebooks_com_search_limit"
        parsed_value = Integer(value.to_s, 10, exception: false)
        return nil if parsed_value&.between?(1, EbooksComClient::MAX_RESULTS)

        "must be between 1 and #{EbooksComClient::MAX_RESULTS}"
      end
    end

    def stored_setting_changed?(key, normalized_value)
      definition = SettingsService::DEFINITIONS[key.to_sym]
      return true unless definition

      posted = Setting.new(value_type: definition[:type])
      posted.typed_value = normalized_value
      stored = Setting.find_by(key: key.to_s)
      if stored
        posted.value != stored.value && posted.typed_value != stored.typed_value
      else
        default_setting = Setting.new(value_type: definition[:type])
        default_setting.typed_value = definition[:default]
        posted.value != default_setting.value && posted.typed_value != default_setting.typed_value
      end
    end

    def indexer_url_message(error)
      detail = error.message.to_s
      if (match = detail.match(/\AInvalid .+ URL: (.+)\z/))
        "must be a valid HTTP or HTTPS URL (#{match[1]})"
      else
        "must be a valid HTTP or HTTPS URL (include http:// or https://)"
      end
    end
  end
end
