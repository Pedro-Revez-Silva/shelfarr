# frozen_string_literal: true

module Kobo
  # A reader keeps one x-kobo-synctoken. With Store coexistence it carries two
  # positions: Shelfarr's own signed cursor and Kobo's Store cursor. Kobo's part
  # can contain account material, so the envelope is encrypted, not just signed,
  # and bound to this reader's current connection address.
  class SyncCursor
    PREFIX = "sf2."
    MAX_BYTES = 16.kilobytes
    MAX_STORE_BYTES = StoreProxy::MAX_HEADER_BYTES
    Parts = Data.define(:local, :store)
    EMPTY = Parts.new(local: nil, store: nil)

    def initialize(device, authorization: nil)
      @device = device
      if StoreProxy.safe_header_value?(authorization, StoreProxy::MAX_HEADER_BYTES)
        key = Rails.application.key_generator.generate_key("shelfarr kobo reader sign-in binding", 32)
        @authorization_binding = OpenSSL::HMAC.hexdigest("SHA256", key, authorization)
      end
    end

    def read(raw)
      raw = raw.to_s
      return EMPTY if raw.empty? || raw.bytesize > MAX_BYTES
      return envelope(raw.delete_prefix(PREFIX)) if raw.start_with?(PREFIX)
      # Shelfarr's earlier single cursor (a signed "data--digest" message).
      # KoboSync verifies it. It is never forwarded to Kobo, even if invalid.
      return Parts.new(local: raw, store: nil) if raw.match?(/--\h{40,128}\z/)

      # An unbound cursor cannot establish which Kobo sign-in it came from.
      # Replay the Store once rather than attaching it to a different account.
      EMPTY
    end

    def write(local:, store:)
      store = nil unless @authorization_binding && StoreProxy.safe_header_value?(store, MAX_STORE_BYTES)
      claims = { "device" => @device.id, "generation" => @device.token_digest, "local" => local, "store" => store,
        "authorization" => @authorization_binding }
      PREFIX + encryptor.encrypt_and_sign(claims, purpose: "kobo-sync-cursor")
    end

    private

    def envelope(value)
      claims = encryptor.decrypt_and_verify(value, purpose: "kobo-sync-cursor")
      return EMPTY unless claims.is_a?(Hash) && claims["device"] == @device.id && claims["generation"] == @device.token_digest

      local = claims["local"] if claims["local"].is_a?(String)
      if @authorization_binding && claims["authorization"] == @authorization_binding && StoreProxy.safe_header_value?(claims["store"], MAX_STORE_BYTES)
        store = claims["store"]
      end
      Parts.new(local: local, store: store)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      EMPTY
    end

    def encryptor
      cipher = "aes-256-gcm"
      key = Rails.application.key_generator.generate_key("shelfarr kobo sync cursor v2", ActiveSupport::MessageEncryptor.key_len(cipher))
      ActiveSupport::MessageEncryptor.new(key, cipher: cipher, serializer: :json, url_safe: true)
    end
  end
end
