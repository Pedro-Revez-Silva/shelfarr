# frozen_string_literal: true

module WebPreview
  class Access
    VARIABLE = "SHELFARR_WEB_PREVIEW_USER_IDS"
    MAX_USERS = 100
    USER_ID = /\A[1-9]\d{0,18}\z/

    @memo = [ :unset, nil ]

    class << self
      def current
        raw = ENV[VARIABLE]
        return @memo.last if @memo.first == raw

        access = new(raw)
        @memo = [ raw&.dup, access ]
        access
      end
    end

    attr_reader :user_ids

    def initialize(raw)
      @user_ids = parse(raw)
    end

    def configured?
      user_ids.any?
    end

    def allows?(user)
      user.present? && user_ids.include?(user.id)
    end

    private

    def parse(raw)
      return [] if raw.blank?

      entries = raw.split(",", -1).map(&:strip)
      valid = entries.size <= MAX_USERS && entries.all? { |entry| entry.match?(USER_ID) }
      unless valid
        Rails.logger.error("#{VARIABLE} is malformed (expected up to #{MAX_USERS} comma-separated user ids); the web preview stays off for everyone")
        return []
      end

      entries.map(&:to_i).uniq.freeze
    end
  end
end
