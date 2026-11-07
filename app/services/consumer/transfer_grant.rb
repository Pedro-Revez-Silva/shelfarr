# frozen_string_literal: true

# A short-lived capability to fetch one exact asset generation without the
# account bearer. Native background transfers persist their request and follow
# redirects unattended, so they must never hold the general credential.
#
# Grants are encrypted, authenticated and purpose-bound, so nothing is stored.
# They name the issuing token, its user, the publication and the asset
# generation; every use re-checks the live token, user and scope.
class Consumer::TransferGrant
  PURPOSE = "consumer_transfer_grant"
  SCOPE = "library:read"
  LIFETIME = 24.hours
  CIPHER = "aes-256-gcm"
  FORMAT = /\A[A-Za-z0-9_-]{32,2048}\z/

  class << self
    # Returns the opaque grant and when it stops working: in LIFETIME, or when
    # the issuing token expires if that is sooner.
    def issue(api_token:, book:, asset_id:, now: Time.current)
      expires_at = [ now + LIFETIME, api_token.expires_at ].compact.min
      claims = { "t" => api_token.id, "u" => api_token.user_id, "b" => book.id.to_s, "a" => asset_id.to_s }
      [ encryptor.encrypt_and_sign(claims, expires_at: expires_at, purpose: PURPOSE), expires_at ]
    end

    # Returns the issuing APIToken when the grant opens this publication and
    # asset, or nil. The asset generation itself is checked when it's opened.
    def verify(value, book_id:, asset_id:)
      return unless value.is_a?(String) && value.match?(FORMAT)

      claims = encryptor.decrypt_and_verify(value, purpose: PURPOSE)
      return unless claims.is_a?(Hash) && claims["b"] == book_id.to_s && claims["a"] == asset_id.to_s

      token = APIToken.active.find_by(id: claims["t"])
      token if token && token.user_id == claims["u"] && token.user && !token.user.deleted? && token.has_scope?(SCOPE)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil # rubocop:disable Shelfarr/RescueToEmpty -- a forged or tampered grant is no grant, never a remote failure
    end

    def encryptor
      key = Rails.application.key_generator.generate_key("shelfarr consumer transfer grant v1", ActiveSupport::MessageEncryptor.key_len(CIPHER))
      ActiveSupport::MessageEncryptor.new(key, cipher: CIPHER, serializer: :json, url_safe: true)
    end
  end
end
