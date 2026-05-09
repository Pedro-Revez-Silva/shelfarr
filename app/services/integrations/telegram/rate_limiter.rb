# frozen_string_literal: true

module Integrations
  module Telegram
    class RateLimiter
      WINDOW = 1.minute
      LIMIT = 20

      class << self
        def allowed?(telegram_user_id)
          return false if telegram_user_id.blank?

          TelegramUpdate.recent_for_user(telegram_user_id, since: WINDOW.ago).count <= LIMIT
        end
      end
    end
  end
end
