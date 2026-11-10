# frozen_string_literal: true

module Kobo
  # Library sync for a reader in Store coexistence mode: Shelfarr's selections
  # first, then the reader's own Store library, using the reader's own Kobo
  # sign-in. A Store failure never advances the Store cursor and never removes
  # or replaces a Shelfarr entitlement, so local books and their reading places
  # survive any Store outage or unexpected response.
  class StoreSync
    Result = Data.define(:items, :token, :more, :headers)

    def initialize(device, endpoint:, proxy: StoreProxy.new)
      @device = device
      @local = KoboSync.new(device, endpoint: endpoint)
      @proxy = proxy
    end

    # Returns a Result, or the Store's own 401/403 response so the reader can
    # refresh its Kobo sign-in exactly as it would when talking to Kobo. Other
    # refusals keep Shelfarr books flowing, as the reader's direct Kobo
    # requests (Store, sign-in refresh) still surface the problem there.
    def call(raw_cursor, headers:, query: "")
      authorization = headers.find { |name, _| name.to_s.casecmp?("Authorization") }&.last
      cursor = SyncCursor.new(@device, authorization: authorization)
      parts = cursor.read(raw_cursor)
      local = @local.call(parts.local)
      store_token = parts.store
      store_items = []
      store_more = false
      extra = {}
      unless local.more
        begin
          response = @proxy.call(method: "GET", path: "/v1/library/sync", query: query, headers: headers, sync_token: store_token)
          if [ 401, 403 ].include?(response.status)
            record("authorization")
            return response
          end
          store_items, store_token, store_more = page(response)
          extra = response.headers.select { |name, _| name.start_with?("x-kobo-") }.except("x-kobo-synctoken", "x-kobo-sync")
          record("ok")
        rescue StoreProxy::Unavailable, StoreProxy::InvalidRequest
          # Kobo answers a malformed or unusable sign-in with 400, not 401.
          record(response && response.status.between?(400, 499) ? "rejected" : "unavailable")
        end
      end
      Result.new(items: local.items + store_items, token: cursor.write(local: local.token, store: store_token),
        more: local.more || store_more, headers: extra)
    rescue StoreProxy::Unavailable
      # A continuation which could not be retained must not be acknowledged.
      StoreProxy::Response.new(status: 503, headers: { "content-type" => "application/json" }, body: "")
    end

    private

    # A page is acknowledged only when it is complete and replayable. Anything
    # else keeps the previous Store cursor so the next sync asks again.
    def page(response)
      raise StoreProxy::Unavailable unless response.status == 200

      items = response.json(Array)
      token = response.headers["x-kobo-synctoken"]
      unless items.all? { |item| item.is_a?(Hash) } && StoreProxy.safe_header_value?(token, SyncCursor::MAX_STORE_BYTES)
        raise StoreProxy::Unavailable
      end

      local_ids = @device.kobo_deliveries.pluck(:entitlement_id).to_set
      items = items.reject { |item| item.values.any? { |value| value.is_a?(Hash) && local_ids.include?(entitlement_id(value)) } }
      [ items, token, response.headers["x-kobo-sync"].to_s.casecmp?("continue") ]
    end

    def entitlement_id(value)
      %w[BookEntitlement BookSubscriptionEntitlement AudiobookEntitlement].each do |key|
        id = value.dig(key, "Id") if value[key].is_a?(Hash)
        return id if id
      end
      value.dig("ReadingState", "EntitlementId") if value["ReadingState"].is_a?(Hash)
    end

    def record(status)
      @device.update_columns(store_status: status, store_checked_at: Time.current)
    end
  end
end
