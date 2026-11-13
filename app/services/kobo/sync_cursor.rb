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
    # A common reverse proxy has a 4 KiB response-header buffer. The cursor
    # must leave room for the remaining headers, even when Kobo's own cursor
    # grows during a full Store replay.
    MAX_WIRE_BYTES = 3.kilobytes
    REFERENCE_TTL = 30.days
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
      token = seal(claims)
      return token if token.bytesize <= MAX_WIRE_BYTES

      # Keep the overflow encrypted in the bounded application cache. Only
      # an authenticated, reader/sign-in-bound reference goes over the wire.
      # Repeated replies with the same claims reuse one cache entry.
      reference = reference_for(claims)
      referenced = claims.except("store").merge("store_reference" => reference)
      encrypted = encryptor.encrypt_and_sign(claims, purpose: "kobo-sync-overflow")
      unless Rails.cache.write(cache_key(reference), encrypted, expires_in: REFERENCE_TTL) && referenced_store(referenced) == store
        raise StoreProxy::Unavailable
      end
      token = seal(referenced)
      raise StoreProxy::Unavailable if token.bytesize > MAX_WIRE_BYTES

      token
    rescue StoreProxy::Unavailable
      raise
    rescue StandardError => error
      Rails.logger.warn("[Kobo] Sync cursor could not be retained (#{error.class.name})")
      raise StoreProxy::Unavailable
    end

    private

    def envelope(value)
      claims = encryptor.decrypt_and_verify(value, purpose: "kobo-sync-cursor")
      return EMPTY unless claims.is_a?(Hash) && claims["device"] == @device.id && claims["generation"] == @device.token_digest

      local = claims["local"] if claims["local"].is_a?(String)
      if @authorization_binding && claims["authorization"] == @authorization_binding
        candidate = claims.key?("store_reference") ? referenced_store(claims) : claims["store"]
        store = candidate if StoreProxy.safe_header_value?(candidate, MAX_STORE_BYTES)
      end
      Parts.new(local: local, store: store)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      EMPTY
    end

    def seal(claims)
      PREFIX + encryptor.encrypt_and_sign(claims, purpose: "kobo-sync-cursor")
    end

    def reference_for(claims)
      key = Rails.application.key_generator.generate_key("shelfarr kobo sync overflow reference", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, claims.to_json)
    end

    def cache_key(reference)
      "kobo-sync-overflow-v1:#{reference}"
    end

    def referenced_store(claims)
      reference = claims["store_reference"]
      return unless reference.is_a?(String) && reference.match?(/\A[0-9a-f]{64}\z/)

      encrypted = Rails.cache.read(cache_key(reference))
      return unless encrypted.is_a?(String) && encrypted.bytesize <= 32.kilobytes

      stored = encryptor.decrypt_and_verify(encrypted, purpose: "kobo-sync-overflow")
      return unless stored.is_a?(Hash) && reference_for(stored) == reference &&
        stored.values_at("device", "generation", "authorization", "local") == claims.values_at("device", "generation", "authorization", "local")

      stored["store"]
    rescue StandardError => error
      # An expired/evicted entry replays Store without rewinding Shelfarr's
      # local cursor or borrowing another reader's Store position.
      Rails.logger.warn("[Kobo] Stored sync cursor unavailable (#{error.class.name})")
      RemoteResult::Failed.new(error)
    end

    def encryptor
      cipher = "aes-256-gcm"
      key = Rails.application.key_generator.generate_key("shelfarr kobo sync cursor v2", ActiveSupport::MessageEncryptor.key_len(cipher))
      ActiveSupport::MessageEncryptor.new(key, cipher: cipher, serializer: :json, url_safe: true)
    end
  end
end
