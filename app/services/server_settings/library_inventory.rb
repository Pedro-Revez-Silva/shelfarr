# frozen_string_literal: true

module ServerSettings
  class LibraryInventory
    RECENT_LIMIT = 50

    attr_reader :recent_items, :count, :available_count, :missing_count, :last_synced_at

    def self.platform_libraries
      return [] unless LibraryPlatformClient.configured?

      LibraryPlatformClient.libraries
    rescue LibraryPlatformClient::Error => e
      Rails.logger.warn "[SettingsController] Failed to fetch #{LibraryPlatformClient.display_name} libraries: #{e.message}"
      RemoteResult::Failed.new(e)
    end

    def self.start_sync
      return false unless LibraryPlatformClient.configured?

      AudiobookshelfLibrarySyncJob.perform_later
      true
    end

    def initialize
      items = LibraryItem.for_active_platform
      @recent_items = items.by_synced_at_desc.limit(RECENT_LIMIT)
      @count = items.count
      @available_count = LibraryItem.available_for_matching.count
      @missing_count = items.where(missing: true).count
      @last_synced_at = @recent_items.maximum(:synced_at)
    end
  end
end
