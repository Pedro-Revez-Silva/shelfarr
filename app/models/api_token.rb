# frozen_string_literal: true

class APIToken < ApplicationRecord
  TOKEN_PREFIX = "shf_"
  AVAILABLE_SCOPES = %w[search:read requests:read requests:write requests:admin users:write].freeze
  SELF_SERVICE_SCOPES = %w[search:read requests:read requests:write].freeze

  belongs_to :user, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true
  validate :scopes_are_known

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    def issue!(name:, user:, scopes:, expires_at: nil)
      raw_token = "#{TOKEN_PREFIX}#{SecureRandom.base58(40)}"
      token = create!(
        name: name,
        user: user,
        scopes: normalize_scopes(scopes).to_json,
        token_digest: digest(raw_token),
        token_prefix: raw_token.first(12),
        expires_at: expires_at
      )

      [ token, raw_token ]
    end

    def authenticate(raw_token)
      return nil if raw_token.blank?

      token = active.find_by(token_digest: digest(raw_token))
      token&.touch(:last_used_at)
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
    scope_list.include?(scope.to_s)
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
