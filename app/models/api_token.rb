# frozen_string_literal: true

class APIToken < ApplicationRecord
  TOKEN_PREFIX = "shf_"
  AVAILABLE_SCOPES = %w[search:read requests:read requests:write requests:admin users:write library:read progress:write].freeze
  SELF_SERVICE_SCOPES = %w[search:read requests:read requests:write library:read progress:write].freeze
  PRIVILEGED_SCOPES = (AVAILABLE_SCOPES - SELF_SERVICE_SCOPES).freeze
  # Credentials a native app received through browser device approval.
  CONSUMER_DEVICE = "consumer_device"

  belongs_to :user, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true
  validate :scopes_are_known

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    def issue!(name:, user:, scopes:, expires_at: nil, issued_via: nil, replaces: nil)
      raw_token = "#{TOKEN_PREFIX}#{SecureRandom.base58(40)}"
      token = create!(
        name: name,
        user: user,
        scopes: normalize_scopes(scopes).to_json,
        token_digest: digest(raw_token),
        token_prefix: raw_token.first(12),
        expires_at: expires_at,
        issued_via: issued_via,
        replaces_api_token_id: replaces&.id
      )

      [ token, raw_token ]
    end

    def authenticate(raw_token)
      return nil if raw_token.blank?

      token = active.find_by(token_digest: digest(raw_token))
      return nil if token.nil? || token.user&.deleted?

      token.retire_replaced_token!
      token.touch(:last_used_at)
      token
    end

    def digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end

    def normalize_scopes(value)
      Array(value).flat_map { |scope| scope.to_s.split(/[,\s]+/) }
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    end
  end

  def scope_list
    parsed = JSON.parse(scopes.to_s)
    self.class.normalize_scopes(parsed)
  rescue JSON::ParserError
    []
  end

  def has_scope?(scope)
    scope = scope.to_s
    return false unless scope_list.include?(scope)
    return true unless PRIVILEGED_SCOPES.include?(scope)

    user&.admin?
  end

  def consumer_device?
    issued_via == CONSUMER_DEVICE
  end

  # An upgraded app credential replaces the one it was approved from, but only
  # once the app has proved it received the new token by using it. A lost
  # token response therefore never leaves the app without a working credential.
  def retire_replaced_token!
    return if replaces_api_token_id.nil?

    APIToken.where(id: replaces_api_token_id, user_id: user_id, revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
    update_columns(replaces_api_token_id: nil)
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  def scopes_are_known
    unknown = scope_list - AVAILABLE_SCOPES
    errors.add(:scopes, "include unknown scopes: #{unknown.join(', ')}") if unknown.any?
  end
end
