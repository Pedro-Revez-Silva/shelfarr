# frozen_string_literal: true

require "digest"

module Integrations
  module Telegram
    class Configuration
      class << self
        def enabled?
          SettingsService.get(:telegram_enabled, default: false)
        end

        def configured?
          enabled? && bot_token.present? && webhook_secret.present?
        end

        def bot_token
          SettingsService.get(:telegram_bot_token).to_s.strip
        end

        def bot_username
          SettingsService.get(:telegram_bot_username).to_s.strip.delete_prefix("@")
        end

        def webhook_secret
          SettingsService.get(:telegram_webhook_secret).to_s.strip
        end

        def allowed_chat_ids
          parse_list(SettingsService.get(:telegram_allowed_chat_ids))
        end

        def notification_enabled_for?(event)
          configured? && notification_events.include?(event.to_s)
        end

        def chat_allowed?(chat_id)
          allowed_chat_ids.include?(chat_id.to_s)
        end

        def user_for(telegram_user_id)
          user = User.active.find_by(telegram_user_id: telegram_user_id.to_s)
          return user if user

          username = user_mappings[telegram_user_id.to_s]
          return nil if username.blank?

          User.active.find_by(username: username)
        end

        def webhook_secret_valid?(provided_secret)
          expected_secret = webhook_secret
          return false if expected_secret.blank?
          return false if provided_secret.blank?

          provided_digest = Digest::SHA256.hexdigest(provided_secret.to_s)
          expected_digest = Digest::SHA256.hexdigest(expected_secret)
          ActiveSupport::SecurityUtils.secure_compare(provided_digest, expected_digest)
        end

        def user_mappings
          raw = SettingsService.get(:telegram_user_mappings).to_s.strip
          return {} if raw.blank?

          parsed_json_mappings(raw) || parsed_line_mappings(raw)
        end

        private

        def parse_list(value)
          value.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?).uniq
        end

        def notification_events
          parse_list(SettingsService.get(:telegram_notification_events))
        end

        def parsed_json_mappings(raw)
          parsed = JSON.parse(raw)
          return nil unless parsed.is_a?(Hash)

          parsed.each_with_object({}) do |(telegram_id, username), mappings|
            mappings[telegram_id.to_s] = username.to_s.strip.downcase if username.present?
          end
        rescue JSON::ParserError
          nil
        end

        def parsed_line_mappings(raw)
          raw.lines.each_with_object({}) do |line, mappings|
            telegram_id, username = line.strip.split(/[=:]/, 2)
            next if telegram_id.blank? || username.blank?

            mappings[telegram_id.strip] = username.strip.downcase
          end
        end
      end
    end
  end
end
