# frozen_string_literal: true

class AudiobookshelfLibrarySyncService
  Result = Data.define(:success, :items_synced, :libraries_synced, :errors) do
    def success?
      success
    end
  end

  def sync!
    errors = []
    items_synced = 0
    libraries_synced = 0
    now = Time.current

    initial_platform = LibraryPlatformClient.active_platform
    initial_explicit_ids = explicit_configured_library_ids
    using_auto_discovery = initial_explicit_ids.empty?

    library_ids = if using_auto_discovery
      load_library_ids_from_configured_client
    else
      initial_explicit_ids
    end

    if library_ids.empty?
      return Result.new(
        success: false,
        items_synced: 0,
        libraries_synced: 0,
        errors: [ "No #{LibraryPlatformClient.display_name} library IDs configured or available." ]
      )
    end

    library_platform = initial_platform
    library_ids.each do |library_id|
      begin
        items = LibraryPlatformClient.library_items(library_id)
        sync_library_items(library_platform, library_id, items, synced_at: now)
        libraries_synced += 1
        items_synced += items.size
      rescue LibraryPlatformClient::Error, StandardError => e
        errors << "#{library_id}: #{e.message}"
        Rails.logger.warn "[AudiobookshelfLibrarySyncService] Failed to sync #{LibraryPlatformClient.display_name} library #{library_id}: #{e.message}"
      end
    end

    # Prune cached rows for libraries that are no longer configured, unless settings changed during the run.
    current_platform = LibraryPlatformClient.active_platform
    current_explicit_ids = explicit_configured_library_ids
    settings_changed = (current_platform != initial_platform) ||
      (using_auto_discovery ? current_explicit_ids.any? : (current_explicit_ids.sort != initial_explicit_ids.sort))

    unless settings_changed
      LibraryItem.for_platform(library_platform)
                 .where.not(library_id: library_ids)
                 .where("synced_at <= ? OR synced_at IS NULL", now)
                 .delete_all
    end

    synced = errors.empty? || items_synced.positive?
    Result.new(
      success: synced,
      items_synced: items_synced,
      libraries_synced: libraries_synced,
      errors: errors
    )
  end

  private

  def explicit_configured_library_ids
    [
      SettingsService.get(:audiobookshelf_audiobook_library_id),
      SettingsService.get(:audiobookshelf_ebook_library_id),
      SettingsService.get(:audiobookshelf_comicbook_library_id),
      SettingsService.get(:audiobookshelf_audiobook_scan_library_ids),
      SettingsService.get(:audiobookshelf_ebook_scan_library_ids),
      SettingsService.get(:audiobookshelf_comicbook_scan_library_ids)
    ].flat_map { |id| id.to_s.split(",").map(&:strip) }.filter_map(&:presence).uniq
  end

  def sync_library_items(library_platform, library_id, items, synced_at:)
    item_ids = []
    now = synced_at

    items.each do |item|
      audiobookshelf_id = item["audiobookshelf_id"]
      next if audiobookshelf_id.blank?

      cached = LibraryItem.find_or_initialize_by(
        library_platform: library_platform,
        library_id: library_id,
        audiobookshelf_id: audiobookshelf_id
      )

      if cached.persisted? && cached.synced_at.present? && cached.synced_at > now
        item_ids << audiobookshelf_id
        next
      end

      cached.title = item["title"]
      cached.subtitle = item["subtitle"]
      cached.author = item["author"]
      cached.narrator = item["narrator"]
      cached.series = item["series"]
      cached.series_position = item["series_position"]
      cached.publisher = item["publisher"]
      cached.language = item["language"]
      cached.description = item["description"]
      cached.isbn = item["isbn"]
      cached.asin = item["asin"]
      cached.published_year = item["published_year"]
      cached.missing = item["missing"] == true
      cached.synced_at = now
      cached.save!
      item_ids << audiobookshelf_id
    end

    LibraryItem.where(library_platform: library_platform, library_id: library_id)
               .where.not(audiobookshelf_id: item_ids)
               .where("synced_at <= ? OR synced_at IS NULL", now)
               .delete_all
  end

  def load_library_ids_from_configured_client
    return [] unless LibraryPlatformClient.configured?

    libraries = LibraryPlatformClient.libraries
    libraries.select(&:audiobook_library?).map(&:id)
  end
end
