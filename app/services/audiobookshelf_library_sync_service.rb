# frozen_string_literal: true

class AudiobookshelfLibrarySyncService
  LIBRARY_ID_SETTINGS_BY_BOOK_TYPE = {
    "audiobook" => %i[
      audiobookshelf_audiobook_library_id
      audiobookshelf_audiobook_scan_library_ids
    ],
    "ebook" => %i[
      audiobookshelf_ebook_library_id
      audiobookshelf_ebook_scan_library_ids
    ],
    "comicbook" => %i[
      audiobookshelf_comicbook_library_id
      audiobookshelf_comicbook_scan_library_ids
    ]
  }.freeze
  SYNC_CONFIGURATION_KEYS = %i[
    library_platform
    audiobookshelf_url
    audiobookshelf_api_key
    bookorbit_url
    bookorbit_username
    bookorbit_password
    grimmory_url
    grimmory_username
    grimmory_password
    audiobookshelf_audiobook_library_id
    audiobookshelf_ebook_library_id
    audiobookshelf_comicbook_library_id
    audiobookshelf_audiobook_scan_library_ids
    audiobookshelf_ebook_scan_library_ids
    audiobookshelf_comicbook_scan_library_ids
  ].freeze
  LIBRARY_ITEM_UPSERT_BATCH_SIZE = 250
  LIBRARY_ITEM_UPDATE_COLUMNS = %i[
    title subtitle author narrator series series_position publisher language
    description isbn asin published_year missing book_type synced_at updated_at
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

    initial_sync_configuration = configuration_snapshot
    initial_platform = configured_active_platform(initial_sync_configuration)
    initial_library_ids_by_book_type = configured_library_ids_by_book_type(initial_sync_configuration)
    initial_explicit_ids = explicit_configured_library_ids(initial_library_ids_by_book_type)
    initial_book_types_by_library_id = book_types_by_library_id(initial_library_ids_by_book_type)
    using_auto_discovery = initial_explicit_ids.empty?

    library_ids = if using_auto_discovery
      load_library_ids_from_configured_client(initial_platform)
    else
      initial_explicit_ids
    end

    unless configuration_unchanged?(initial_sync_configuration)
      return Result.new(
        success: false,
        items_synced: 0,
        libraries_synced: 0,
        errors: [ "Library settings changed during synchronization" ]
      )
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
        items = LibraryPlatformClient.library_items(library_id, platform: initial_platform)
        publish_library_snapshot!(
          library_platform,
          library_id,
          items,
          book_type: initial_book_types_by_library_id[library_id],
          configuration: initial_sync_configuration,
          synced_at: now
        )
        libraries_synced += 1
        items_synced += items.size
      rescue ActiveRecord::StatementTimeout
        raise
      rescue LibraryPlatformClient::Error, StandardError => e
        errors << "#{library_id}: #{e.message}"
        Rails.logger.warn "[AudiobookshelfLibrarySyncService] Failed to sync #{LibraryPlatformClient.display_name} library #{library_id}: #{e.message}"
      end
    end

    # Prune cached rows for libraries that are no longer configured, unless settings changed during the run.
    prune_unconfigured_libraries!(
      library_platform,
      library_ids,
      configuration: initial_sync_configuration,
      synced_at: now
    )

    synced = errors.empty? || items_synced.positive?
    Result.new(
      success: synced,
      items_synced: items_synced,
      libraries_synced: libraries_synced,
      errors: errors
    )
  end

  private

  def configured_library_ids_by_book_type(configuration)
    library_ids_by_book_type = LIBRARY_ID_SETTINGS_BY_BOOK_TYPE.transform_values do |setting_keys|
      setting_keys.flat_map do |key|
        configuration[key].to_s.split(",").map(&:strip)
      end.filter_map(&:presence).uniq.sort
    end

    if configuration[:audiobookshelf_comicbook_library_id].blank?
      ebook_delivery_id = configuration[:audiobookshelf_ebook_library_id].to_s.strip.presence
      library_ids_by_book_type["comicbook"] |= [ ebook_delivery_id ] if ebook_delivery_id
    end

    library_ids_by_book_type
  end

  def explicit_configured_library_ids(library_ids_by_book_type)
    library_ids_by_book_type.values.flatten.uniq
  end

  def book_types_by_library_id(library_ids_by_book_type)
    library_ids_by_book_type.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(book_type, ids), result|
      ids.each { |id| result[id] << book_type }
    end.transform_values do |book_types|
      if book_types.one?
        book_types.first
      elsif book_types.sort == %w[comicbook ebook]
        "ebook_or_comic"
      end
    end
  end

  def sync_configuration
    SYNC_CONFIGURATION_KEYS.index_with { |key| SettingsService.get(key) }
  end

  def configuration_snapshot
    Setting.transaction { sync_configuration }
  end

  def configured_active_platform(configuration)
    platform = configuration[:library_platform].to_s.strip.downcase
    SettingsService::LIBRARY_PLATFORMS.include?(platform) ? platform : "audiobookshelf"
  end

  def configuration_unchanged?(configuration)
    sync_configuration == configuration
  end

  def ensure_configuration_unchanged!(configuration)
    return if configuration_unchanged?(configuration)

    raise LibraryPlatformClient::Error, "Library settings changed during synchronization"
  end

  def publish_library_snapshot!(library_platform, library_id, items, book_type:, configuration:, synced_at:)
    rows, item_ids = library_item_snapshot(
      library_platform,
      library_id,
      items,
      book_type: book_type,
      synced_at: synced_at
    )

    LibraryItem.transaction do
      ensure_configuration_unchanged!(configuration)
      sync_library_items(
        library_platform,
        library_id,
        rows,
        item_ids: item_ids,
        synced_at: synced_at
      )
      ensure_configuration_unchanged!(configuration)
    end
  end

  def prune_unconfigured_libraries!(library_platform, library_ids, configuration:, synced_at:)
    LibraryItem.transaction do
      ensure_configuration_unchanged!(configuration)
      LibraryItem.for_platform(library_platform)
        .where.not(library_id: library_ids)
        .where("synced_at <= ? OR synced_at IS NULL", synced_at)
        .delete_all
      ensure_configuration_unchanged!(configuration)
    end
  rescue LibraryPlatformClient::Error
    nil
  end

  def library_item_snapshot(library_platform, library_id, items, book_type:, synced_at:)
    rows_by_id = {}
    items.each do |item|
      audiobookshelf_id = item["audiobookshelf_id"]
      next if audiobookshelf_id.blank?

      rows_by_id[audiobookshelf_id] = {
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
        book_type: book_type,
        synced_at: synced_at,
        created_at: synced_at,
        updated_at: synced_at
      }
    end

    [ rows_by_id.values, rows_by_id.keys ]
  end

  def sync_library_items(library_platform, library_id, rows, item_ids:, synced_at:)
    rows.each_slice(LIBRARY_ITEM_UPSERT_BATCH_SIZE) do |batch|
      LibraryItem.upsert_all(
        batch,
        unique_by: %i[library_platform library_id audiobookshelf_id],
        on_duplicate: library_item_on_duplicate_sql,
        record_timestamps: false
      )
    end

    LibraryItem.where(library_platform: library_platform, library_id: library_id)
               .where.not(audiobookshelf_id: item_ids)
               .where("synced_at <= ? OR synced_at IS NULL", synced_at)
               .delete_all
  end

  def library_item_on_duplicate_sql
    @library_item_on_duplicate_sql ||= begin
      assignments = LIBRARY_ITEM_UPDATE_COLUMNS.map do |column|
        quoted_column = LibraryItem.connection.quote_column_name(column)
        "#{quoted_column}=excluded.#{quoted_column}"
      end.join(", ")
      Arel.sql(
        "#{assignments} WHERE excluded.synced_at >= library_items.synced_at " \
          "OR library_items.synced_at IS NULL"
      )
    end
  end

  def load_library_ids_from_configured_client(platform)
    return [] unless LibraryPlatformClient.configured?(platform: platform)

    libraries = LibraryPlatformClient.libraries(platform: platform)
    libraries.select(&:audiobook_library?).map(&:id)
  end
end
