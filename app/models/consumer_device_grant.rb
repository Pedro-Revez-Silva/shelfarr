# frozen_string_literal: true

class ConsumerDeviceGrant < ApplicationRecord
  belongs_to :user, optional: true

  LIFETIME = 10.minutes
  TOKEN_LIFETIME = 30.days
  CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXYZ23456789"
  SCOPES = %w[library:read progress:write].freeze

  validates :client_name, presence: true, length: { maximum: 80 }

  def self.issue!(client_name:)
    device_code = SecureRandom.hex(32)
    user_code = Array.new(8) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
    # Retain recent consumed rows for polling results; expire abandoned grants.
    where("expires_at < ?", 1.day.ago).delete_all
    grant = create!(client_name: client_name, device_code_digest: digest(device_code),
      user_code_digest: digest(user_code), expires_at: LIFETIME.from_now)
    [ grant, device_code, "#{user_code.first(4)}-#{user_code.last(4)}" ]
  end

  def self.for_user_code(code)
    return unless code.is_a?(String)

    normalized = code.upcase.delete("- ")
    return unless normalized.match?(/\A[#{CODE_ALPHABET}]{8}\z/)

    find_by(user_code_digest: digest(normalized))
  end

  def self.for_device_code(code)
    return unless code.is_a?(String) && code.match?(/\A[0-9a-f]{64}\z/)

    find_by(device_code_digest: digest(code))
  end

  def self.digest(code)
    Digest::SHA256.hexdigest(code)
  end

  def pending?
    expires_at.future? && approved_at.nil? && denied_at.nil? && consumed_at.nil?
  end

  def decide!(actor:, allow:)
    with_lock do
      return false unless pending? && !actor.deleted?

      update!(user: actor, **(allow ? { approved_at: Time.current } : { denied_at: Time.current }))
      true
    end
  end

  # Return errors from inside the transaction rather than raising: throttling
  # and last-poll timestamps must commit even for a pending/slow response.
  def exchange!
    with_lock do
      now = Time.current
      if consumed_at || expires_at <= now
        { error: "expired_token" }
      elsif denied_at || user&.deleted?
        { error: "access_denied" }
      elsif last_polled_at && last_polled_at > poll_interval.seconds.ago
        update!(last_polled_at: now, poll_interval: [ poll_interval + 5, 60 ].min)
        { error: "slow_down" }
      elsif approved_at.nil?
        update!(last_polled_at: now)
        { error: "authorization_pending" }
      else
        _, raw = APIToken.issue!(name: client_name, user: user, scopes: SCOPES, expires_at: TOKEN_LIFETIME.from_now)
        update!(consumed_at: now)
        { access_token: raw, token_type: "Bearer", scope: SCOPES.join(" "), expires_in: TOKEN_LIFETIME.to_i }
      end
    end
  end
end
