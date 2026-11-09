# frozen_string_literal: true

module Kobo
  # Asks Kobo, with the owner's own account connection, for a fresh signed
  # link to the verified DRM-free variant of one purchased title. Links are
  # short-lived and returned only to the downloader; they are never stored.
  #
  # The single-title metadata request is tried first. If Kobo answers it
  # unexpectedly, the bounded library sync (the read-only path used by the
  # catalogue) is scanned for the same entitlement instead.
  class DownloadLocator
    Located = Data.define(:revision_id, :choice, :purchased)

    def initialize(account, client: AccountClient.new(account))
      @account = account
      @client = client
      @refreshed = false
    end

    # Returns a Located, or nil when Kobo no longer lists the title.
    def call(book)
      metadata = with_refresh { @client.book_metadata(book.entitlement_id) }
      located(metadata, purchased: book.ownership_type == "purchased")
    rescue HttpClient::Error => error
      raise unless error.code == "protocol_changed"

      from_library(book)
    end

    private

    def located(metadata, purchased:)
      revision = metadata["RevisionId"].is_a?(String) && metadata["RevisionId"].bytesize <= 200 ? metadata["RevisionId"] : nil
      Located.new(revision_id: revision, choice: DownloadRights.classify(metadata["DownloadUrls"]), purchased: purchased)
    end

    def from_library(book)
      cursor = nil
      seen = Set.new
      bytes = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      CatalogueReader::MAX_PAGES.times do
        page = with_refresh { @client.library_page(cursor: cursor) }
        bytes += page.bytes
        if bytes > CatalogueReader::MAX_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > CatalogueReader::MAX_SECONDS
          raise HttpClient::Error, "protocol_changed"
        end

        page.items.each do |item|
          payload = item["NewEntitlement"] || item["ChangedEntitlement"]
          next unless payload.is_a?(Hash) && payload["BookEntitlement"].is_a?(Hash) && payload["BookMetadata"].is_a?(Hash)

          entitlement = payload["BookEntitlement"]
          next unless entitlement["Id"] == book.entitlement_id
          return nil if entitlement["IsRemoved"] == true

          return located(payload["BookMetadata"], purchased: entitlement["OriginCategory"].to_s.casecmp?("purchased"))
        end
        return nil unless page.more
        raise HttpClient::Error, "protocol_changed" unless seen.add?(page.cursor)

        cursor = page.cursor
      end
      raise HttpClient::Error, "protocol_changed"
    end

    def with_refresh
      yield
    rescue HttpClient::Error => error
      raise unless error.code == "credentials_expired" && !@refreshed

      @refreshed = true
      tokens = @client.refresh
      raise ActiveRecord::StaleObjectError unless User.active.exists?(@account.user_id)

      @account.update!(tokens)
      yield
    end
  end
end
