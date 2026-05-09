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
          enabled? && bot_token.present? && (polling? || webhook_secret.present?)
        end

        def polling?
          update_mode == "polling"
        end

        def webhook?
          update_mode == "webhook"
        end

        def update_mode
          mode = SettingsService.get(:telegram_update_mode).to_s.strip.downcase
          %w[polling webhook].include?(mode) ? mode : "polling"
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
          authorization = chat_authorization(chat_id)
          return false if authorization&.paused?
          return true if authorization&.enabled?

          allowed_chat_ids.include?(chat_id.to_s)
        end

        def chat_paused?(chat_id)
          chat_authorization(chat_id)&.paused? || false
        end

        def request_user
          username = SettingsService.get(:telegram_request_username).to_s.strip.downcase
          user = User.active.find_by(username: username) if username.present?
          user || User.active.admin.order(:created_at).first || User.active.order(:created_at).first
        end

        def webhook_secret_valid?(provided_secret)
          expected_secret = webhook_secret
          return false if expected_secret.blank?
          return false if provided_secret.blank?

          provided_digest = Digest::SHA256.hexdigest(provided_secret.to_s)
          expected_digest = Digest::SHA256.hexdigest(expected_secret)
          ActiveSupport::SecurityUtils.secure_compare(provided_digest, expected_digest)
        end

        private

        def chat_authorization(chat_id)
          TelegramChatAuthorization.find_by(chat_id: chat_id.to_s)
        end

        def parse_list(value)
          value.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?).uniq
        end

        def notification_events
          parse_list(SettingsService.get(:telegram_notification_events))
        end
      end
    end
  end
end
