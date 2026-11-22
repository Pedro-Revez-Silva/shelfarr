# frozen_string_literal: true

module WebPreview
  module SecretRedaction
    MASK = "[hidden]"
    MAX_LENGTH = 500
    MIN_SECRET_LENGTH = 4

    module_function

    def call(text)
      return nil if text.nil?

      redacted = secret_values.reduce(text.to_s) { |result, secret| result.gsub(secret, MASK) }
      redacted.first(MAX_LENGTH)
    end

    def secret_values
      keys = SettingsService::DEFINITIONS.keys.select { |key| SettingsService.secret_setting_key?(key) || AdminSettings::WRITE_ONLY_ADDRESSES.include?(key) }
      values = keys.filter_map { |key| SettingsService.get(key).to_s.strip.presence }
      (values + values.filter_map { |value| value.split("?", 2)[1] })
        .select { |value| value.length >= MIN_SECRET_LENGTH }
        .uniq
        .sort_by { |value| -value.length }
    end
  end
end
