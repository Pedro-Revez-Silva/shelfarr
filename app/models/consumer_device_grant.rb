# frozen_string_literal: true

class ConsumerDeviceGrant < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :replaces_api_token, class_name: "APIToken", optional: true

  LIFETIME = 10.minutes
  TOKEN_LIFETIME = 30.days
  CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXYZ23456789"
  # Every app connection may read the library and save the reader's place.
  SCOPES = %w[library:read progress:write].freeze
  # Requesting is opt-in, approved as one clearly described permission. None of
  # these scopes is privileged: requests stay the approving account's own.
  REQUEST_SCOPES = %w[search:read requests:read requests:write].freeze

  class InvalidScope < StandardError; end

  validates :client_name, presence: true, length: { maximum: 80 }

  # `scope` is the space-separated OAuth-style list a client asked for. It may
  # name only the base pair and the whole requesting bundle. `replaces` is the
  # app's current credential when it is asking to add requesting to itself.
  def self.issue!(client_name:, scope: nil, replaces: nil)
    scopes = requested_scopes(scope)
    device_code = SecureRandom.hex(32)
    user_code = Array.new(8) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
    # Retain recent consumed rows for polling results; expire abandoned grants.
    where("expires_at < ?", 1.day.ago).delete_all
    grant = create!(client_name: client_name, device_code_digest: digest(device_code),
      user_code_digest: digest(user_code), expires_at: LIFETIME.from_now,
      scopes: scopes == SCOPES ? nil : scopes.to_json, replaces_api_token: replaces)
    [ grant, device_code, "#{user_code.first(4)}-#{user_code.last(4)}" ]
  end

  def self.requested_scopes(scope)
    return SCOPES if scope.nil?
    raise InvalidScope unless scope.is_a?(String) && scope.bytesize <= 200

    names = scope.split(" ").reject(&:empty?).uniq
    raise InvalidScope unless (names - SCOPES - REQUEST_SCOPES).empty?

    extra = names & REQUEST_SCOPES
    raise InvalidScope unless extra.empty? || extra.sort == REQUEST_SCOPES.sort

    extra.empty? ? SCOPES : SCOPES + REQUEST_SCOPES
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

  def granted_scopes
    return SCOPES if scopes.blank?

    parsed = JSON.parse(scopes)
    parsed.is_a?(Array) ? self.class.requested_scopes(parsed.join(" ")) : SCOPES
  rescue JSON::ParserError, InvalidScope
    SCOPES
  end

  def requesting?
    (REQUEST_SCOPES - granted_scopes).empty?
  end

  def upgrade?
    replaces_api_token_id.present?
  end

  # An upgrade adds permission to one existing connection, so only the account
  # that connection belongs to may approve or decline it.
  def decidable_by?(actor)
    return false if actor.nil? || actor.deleted?
    return true unless upgrade?

    replaces_api_token&.user_id == actor.id
  end

  def pending?
    expires_at.future? && approved_at.nil? && denied_at.nil? && consumed_at.nil?
  end

  def decide!(actor:, allow:)
    with_lock do
      return false unless pending? && decidable_by?(actor)

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
      elsif upgrade? && replaces_api_token&.user_id != user_id
        # Defence in depth: approval already refuses this.
        update!(consumed_at: now)
        { error: "access_denied" }
      else
        scope_list = granted_scopes
        _, raw = APIToken.issue!(name: client_name, user: user, scopes: scope_list, expires_at: TOKEN_LIFETIME.from_now,
          issued_via: APIToken::CONSUMER_DEVICE, replaces: replaces_api_token)
        update!(consumed_at: now)
        { access_token: raw, token_type: "Bearer", scope: scope_list.join(" "), expires_in: TOKEN_LIFETIME.to_i }
      end
    end
  end
end
