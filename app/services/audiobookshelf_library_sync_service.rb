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

    library_ids = configured_library_ids
    if library_ids.empty?
      return Result.new(
        success: false,
        items_synced: 0,
        libraries_synced: 0,
        errors: [ "No Audiobookshelf library IDs configured or available." ]
      )
    end

    library_ids.each do |library_id|
      begin
        items = AudiobookshelfClient.library_items(library_id)
        sync_library_items(library_id, items, synced_at: now)
        libraries_synced += 1
        items_synced += items.size
      rescue AudiobookshelfClient::Error, StandardError => e
        errors << "#{library_id}: #{e.message}"
        Rails.logger.warn "[AudiobookshelfLibrarySyncService] Failed to sync library #{library_id}: #{e.message}"
      end
    end

    synced = errors.empty? || items_synced.positive?
    Result.new(
      success: synced,
      items_synced: items_synced,
      libraries_synced: libraries_synced,
      errors: errors
    )
  end

  def configured_library_ids
    return @configured_library_ids if defined?(@configured_library_ids)

    @configured_library_ids = begin
      configured_ids = [
        SettingsService.get(:audiobookshelf_audiobook_library_id),
        SettingsService.get(:audiobookshelf_ebook_library_id)
      ].filter_map(&:presence).uniq

      if configured_ids.any?
        configured_ids
      else
        load_library_ids_from_configured_client
      end
    end
  end

  private

  def sync_library_items(library_id, items, synced_at:)
    item_ids = []
    now = synced_at

    items.each do |item|
      audiobookshelf_id = item["audiobookshelf_id"]
      next if audiobookshelf_id.blank?

      cached = LibraryItem.find_or_initialize_by(library_id: library_id, audiobookshelf_id: audiobookshelf_id)
      cached.title = item["title"]
      cached.author = item["author"]
      cached.synced_at = now
      cached.save!
      item_ids << audiobookshelf_id
    end

    LibraryItem.where(library_id: library_id).where.not(audiobookshelf_id: item_ids).delete_all
  end

  def load_library_ids_from_configured_client
    return [] unless AudiobookshelfClient.configured?

    libraries = AudiobookshelfClient.libraries
    libraries.select(&:audiobook_library?).map(&:id)
  end
end
