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
      SettingsService::DEFINITIONS.keys
        .select { |key| SettingsService.secret_setting_key?(key) }
        .filter_map { |key| SettingsService.get(key).to_s.presence }
        .select { |value| value.length >= MIN_SECRET_LENGTH }
        .sort_by { |value| -value.length }
    end
  end
end
