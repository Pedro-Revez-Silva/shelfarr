# frozen_string_literal: true

module WebPreview
  class BookHandoff
    TTL = 1.hour
    TOKEN = /\A[A-Za-z0-9_-]{32}\z/
    FIELDS = %i[work_id links title author year description cover_url].freeze

    def self.store(user:, details:)
      token = SecureRandom.urlsafe_base64(24)
      token if Rails.cache.write(key(user, token), details.slice(*FIELDS), expires_in: TTL)
    rescue StandardError => error
      Rails.logger.warn("[WebPreview::BookHandoff] Cache write failed: #{error.class}")
      nil
    end

    def self.fetch(user:, token:, work_id:)
      return {} unless token.is_a?(String) && token.match?(TOKEN)

      details = Rails.cache.read(key(user, token))
      details.is_a?(Hash) && details[:work_id] == work_id ? details : {}
    rescue StandardError => error
      Rails.logger.warn("[WebPreview::BookHandoff] Cache read failed: #{error.class}")
      {}
    end

    def self.key(user, token)
      [ "web_preview", "book_handoff", user.id, token ].join("/")
    end
  end
end
