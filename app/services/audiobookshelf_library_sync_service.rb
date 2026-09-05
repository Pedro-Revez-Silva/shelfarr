# frozen_string_literal: true

class AudiobookshelfLibrarySyncService
  UPSERT_BATCH_SIZE = 500
  UPSERT_UNIQUE_BY = %i[library_platform library_id audiobookshelf_id].freeze
  UPSERT_UPDATE_COLUMNS = %i[
    title subtitle author narrator series series_position publisher language
    description isbn asin published_year missing synced_at updated_at
  ].freeze

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
      load_library_ids_from_configured_client(initial_platform)
    else
      initial_explicit_ids
    end

    if library_ids.empty?
      return Result.new(
        success: false,
        items_synced: 0,
        libraries_synced: 0,
        errors: [ "No #{LibraryPlatformClient.display_name(initial_platform)} library IDs configured or available." ]
      )
    end

    library_platform = initial_platform
    library_ids.each do |library_id|
      begin
        items = LibraryPlatformClient.library_items(library_id, platform: library_platform)
        synced_count = sync_library_items(library_platform, library_id, items, synced_at: now)
        libraries_synced += 1
        items_synced += synced_count
      rescue LibraryPlatformClient::Error, StandardError => e
        errors << "#{library_id}: #{e.message}"
        Rails.logger.warn "[AudiobookshelfLibrarySyncService] Failed to sync #{LibraryPlatformClient.display_name(library_platform)} library #{library_id}: #{e.message}"
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
    validate_sync_scope!(library_platform, library_id)
    items_by_id = items.each_with_object({}) do |item, indexed|
      audiobookshelf_id = item["audiobookshelf_id"]
      next if audiobookshelf_id.blank?

      indexed[audiobookshelf_id.to_s] = item
    end
    item_ids = items_by_id.keys
    written_at = Time.current
    items_by_id.each_slice(UPSERT_BATCH_SIZE) do |batch_items|
      batch = batch_items.map do |audiobookshelf_id, item|
        library_item_attributes(
          library_platform,
          library_id,
          audiobookshelf_id,
          item,
          synced_at: synced_at,
          written_at: written_at
        )
      end
      LibraryItem.upsert_all(
        batch,
        unique_by: UPSERT_UNIQUE_BY,
        on_duplicate: upsert_update_sql,
        record_timestamps: false
      )
    end

    LibraryItem.where(library_platform: library_platform, library_id: library_id)
               .where.not(audiobookshelf_id: item_ids)
               .where("synced_at <= ? OR synced_at IS NULL", synced_at)
               .delete_all

    item_ids.size
  end

  def library_item_attributes(library_platform, library_id, audiobookshelf_id, item, synced_at:, written_at:)
    {
      library_platform: library_platform,
      library_id: library_id,
      audiobookshelf_id: audiobookshelf_id,
      title: item["title"],
      subtitle: item["subtitle"],
      author: item["author"],
      narrator: item["narrator"],
      series: item["series"],
      series_position: item["series_position"],
      publisher: item["publisher"],
      language: item["language"],
      description: item["description"],
      isbn: item["isbn"],
      asin: item["asin"],
      published_year: item["published_year"],
      missing: item["missing"] == true,
      synced_at: synced_at,
      created_at: written_at,
      updated_at: written_at
    }
  end

  def upsert_update_sql
    connection = LibraryItem.connection
    assignments = UPSERT_UPDATE_COLUMNS.map do |column|
      quoted_column = connection.quote_column_name(column)
      "#{quoted_column}=excluded.#{quoted_column}"
    end.join(",")
    table = connection.quote_table_name(LibraryItem.table_name)
    synced_at = connection.quote_column_name(:synced_at)

    Arel.sql(
      "#{assignments} WHERE #{table}.#{synced_at} IS NULL " \
        "OR #{table}.#{synced_at} <= excluded.#{synced_at}"
    )
  end

  def validate_sync_scope!(library_platform, library_id)
    valid_platform = SettingsService::LIBRARY_PLATFORMS.include?(library_platform.to_s)
    return if valid_platform && library_id.present?

    invalid_item = LibraryItem.new(
      library_platform: library_platform,
      library_id: library_id,
      audiobookshelf_id: "bulk-sync-validation"
    )
    invalid_item.validate
    raise ActiveRecord::RecordInvalid, invalid_item
  end

  def load_library_ids_from_configured_client(platform)
    return [] unless LibraryPlatformClient.configured?(platform: platform)

    libraries = LibraryPlatformClient.libraries(platform: platform)
    libraries.select(&:audiobook_library?).map(&:id)
  end
end
