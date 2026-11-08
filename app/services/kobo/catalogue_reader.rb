# frozen_string_literal: true

require "set"

module Kobo
  # Reads metadata only. Download links, content licences, protected book bytes,
  # bookmarks, and account settings are neither fetched nor persisted here.
  class CatalogueReader
    MAX_PAGES = 100
    MAX_BOOKS = 20_000
    MAX_BYTES = 32.megabytes
    MAX_SECONDS = 180

    def initialize(account)
      @account = account
      @client = AccountClient.new(account)
      @refreshed = false
    end

    def call
      books = {}
      cursors = Set.new
      cursor = nil
      bytes = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      MAX_PAGES.times do
        page = fetch_page(cursor)
        bytes += page.bytes
        raise HttpClient::Error, "catalogue_limit" if bytes > MAX_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > MAX_SECONDS

        page.items.each do |item|
          entry = normalize(item)
          books[entry.fetch(:entitlement_id)] = entry if entry
          raise HttpClient::Error, "catalogue_limit" if books.size > MAX_BOOKS
        end
        return books.values unless page.more

        raise HttpClient::Error, "protocol_changed" unless cursors.add?(page.cursor)

        cursor = page.cursor
      end
      raise HttpClient::Error, "catalogue_limit"
    end

    private

    def fetch_page(cursor)
      @client.library_page(cursor: cursor)
    rescue HttpClient::Error => error
      raise unless error.code == "credentials_expired" && !@refreshed

      @refreshed = true
      tokens = @client.refresh
      raise ActiveRecord::StaleObjectError unless User.active.exists?(@account.user_id)

      @account.update!(tokens)
      @client.library_page(cursor: cursor)
    end

    def normalize(item)
      payload = item["NewEntitlement"] || item["ChangedEntitlement"]
      return unless payload
      # Kobo also sends subscription-account records through these events.
      # They describe the subscription itself, rather than a catalogue title.
      return if payload.is_a?(Hash) && payload.keys == [ "BookSubscriptionEntitlement" ] && payload["BookSubscriptionEntitlement"].is_a?(Hash)

      raise HttpClient::Error, "protocol_changed" unless payload.is_a?(Hash) && payload["BookEntitlement"].is_a?(Hash)

      entitlement = payload.fetch("BookEntitlement")
      id = text(entitlement["Id"], 200)
      metadata = payload["BookMetadata"]
      if !metadata && entitlement["IsRemoved"] == true
        return { entitlement_id: id, archived: true }
      end
      raise HttpClient::Error, "protocol_changed" unless metadata.is_a?(Hash)

      contributors = metadata["Contributors"] || []
      unless contributors.is_a?(Array) && contributors.size <= 100
        raise HttpClient::Error, "protocol_changed"
      end
      author = contributors.filter_map do |value|
        name = value.is_a?(Hash) ? value["Name"] : value
        text(name, 1024) if name.present?
      end.join(", ")
      { entitlement_id: id, revision_id: metadata["RevisionId"] ? text(metadata["RevisionId"], 200) : nil,
        title: text(metadata["Title"], 4096), author: author, media_type: media_type(metadata),
        ownership_type: ownership_type(entitlement), archived: entitlement["IsRemoved"] == true }
    end

    def media_type(metadata)
      type = metadata["ContentType"].to_s.downcase
      return "audiobook" if type.include?("audio") || metadata["IsAudioBook"] == true
      return "ebook" if type.include?("book") || metadata["DownloadUrls"].is_a?(Array) && metadata["DownloadUrls"].any? { |url| url.is_a?(Hash) && %w[EPUB EPUB3 KEPUB].include?(url["Format"]) }

      "unknown"
    end

    def ownership_type(entitlement)
      case entitlement["OriginCategory"].to_s.downcase
      when "purchased" then "purchased"
      when "subscription", "koboplus" then "subscription"
      when "preview" then "preview"
      else "unknown"
      end
    end

    def text(value, maximum)
      raise HttpClient::Error, "protocol_changed" unless value.is_a?(String) && value.present? && value.bytesize <= maximum

      value
    end
  end
end
