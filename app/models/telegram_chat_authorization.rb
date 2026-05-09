# frozen_string_literal: true

require "digest"

class TelegramChatAuthorization < ApplicationRecord
  CODE_TTL = 2.minutes

  belongs_to :approved_by, class_name: "User", optional: true

  validates :chat_id, presence: true, uniqueness: true

  scope :approved, -> { where.not(approved_at: nil) }
  scope :enabled, -> { approved.where(paused_at: nil) }
  scope :pending, -> { where(approved_at: nil).where.not(code_digest: nil, code_generated_at: nil) }
  scope :valid_pending, -> { pending.where("code_generated_at >= ?", CODE_TTL.ago) }

  class << self
    def issue!(chat_id:, chat_title:, requested_by_telegram_user_id:, requested_by_telegram_username:)
      code = format("%06d", SecureRandom.random_number(1_000_000))
      authorization = find_or_initialize_by(chat_id: chat_id.to_s)
      authorization.update!(
        chat_title: chat_title.to_s.strip.presence,
        code_digest: digest(code),
        code_generated_at: Time.current,
        approved_at: nil,
        approved_by: nil,
        requested_by_telegram_user_id: requested_by_telegram_user_id.to_s.presence,
        requested_by_telegram_username: requested_by_telegram_username.to_s.strip.presence
      )

      [ authorization, code ]
    end

    def approve_code!(code, approved_by:)
      authorization = valid_pending.detect { |pending| pending.code_valid?(code) }
      return nil unless authorization

      authorization.approve!(approved_by: approved_by)
      authorization
    end

    def digest(code)
      Digest::SHA256.hexdigest(code.to_s.strip)
    end
  end

  def approved?
    approved_at.present?
  end

  def enabled?
    approved? && !paused?
  end

  def paused?
    paused_at.present?
  end

  def expired?
    code_generated_at.blank? || code_generated_at < CODE_TTL.ago
  end

  def code_valid?(code)
    return false if code_digest.blank?
    return false if expired?

    ActiveSupport::SecurityUtils.secure_compare(self.class.digest(code), code_digest)
  end

  def approve!(approved_by:)
    update!(
      approved_at: Time.current,
      approved_by: approved_by,
      paused_at: nil,
      code_digest: nil,
      code_generated_at: nil
    )
  end

  def pause!
    update!(paused_at: Time.current)
  end

  def resume!
    update!(paused_at: nil)
  end
end
