# frozen_string_literal: true

require "set"

class LibraryController < ApplicationController
  CATALOG_ITEMS_PER_PAGE = 50
  SOURCE_FILTERS = %w[audible].freeze

  CatalogEntry = Data.define(:kind, :record) do
    def book?
      kind == :book
    end
  end

  # The catalog is a projection over two tables, not an Active Record relation.
  # Keep the merge, filtering, stable ordering, count, and page clamp inside one
  # SQLite query so a page render never materializes the rest of the library.
  class CatalogQuery
    MAX_REQUESTED_PAGE = 1_000_000_000
    Projection = Data.define(:kind, :id, :audible_tag)
    Result = Data.define(:entries, :total, :page)

    def initialize(query:, type_filter:, source_filter:, owned_library_connection:, page:)
      @query = query
      @type_filter = type_filter
      @source_filter = source_filter
      @owned_library_connection = owned_library_connection
      @requested_page = page.to_i.clamp(1, MAX_REQUESTED_PAGE)
    end

    def call
      register_sqlite_functions! if connection.adapter_name == "SQLite"
      rows = connection.select_all(catalog_sql).to_a
      metadata = rows.shift
      Result.new(
        entries: rows.map { |row| projection(row) },
        total: metadata.fetch("total").to_i,
        page: metadata.fetch("catalog_page").to_i
      )
    end

    private

    attr_reader :query, :type_filter, :source_filter, :owned_library_connection,
      :requested_page

    def catalog_sql
      <<~SQL.squish
        WITH
        normalized_library_identifiers AS MATERIALIZED (
          #{normalized_library_identifiers_sql}
        ),
        normalized_book_identifiers AS MATERIALIZED (
          #{normalized_book_identifiers_sql}
        ),
        normalized_owned_identifiers AS MATERIALIZED (
          #{normalized_owned_identifiers_sql}
        ),
        dynamic_identifier_matches AS MATERIALIZED (
          #{dynamic_identifier_matches_sql}
        ),
        audible_book_tags AS MATERIALIZED (
          #{audible_book_tags_sql}
        ),
        dynamic_book_search_matches AS MATERIALIZED (
          #{dynamic_book_search_matches_sql}
        ),
        raw_book_entries AS MATERIALIZED (
          #{raw_book_entries_sql}
        ),
        book_entries AS (
          SELECT kind, record_id, title, author, audible_tag
          FROM raw_book_entries
          WHERE #{book_filter_sql}
        ),
        owned_entries AS (
          #{owned_entries_sql}
        ),
        catalog_entries AS MATERIALIZED (
          SELECT * FROM book_entries
          UNION ALL
          SELECT * FROM owned_entries
        ),
        numbered_entries AS MATERIALIZED (
          SELECT
            kind,
            record_id,
            audible_tag,
            ROW_NUMBER() OVER (
              ORDER BY #{catalog_lower_sql('title')},
                #{catalog_lower_sql('author')}, kind, record_id
            ) AS catalog_row
          FROM catalog_entries
        ),
        catalog_totals AS (
          SELECT COUNT(*) AS total FROM numbered_entries
        ),
        page_bounds AS (
          SELECT
            CASE
              WHEN total = 0 THEN 1
              WHEN #{requested_offset} >= total
                THEN (CAST((total - 1) / #{CATALOG_ITEMS_PER_PAGE} AS INTEGER) *
                  #{CATALOG_ITEMS_PER_PAGE}) + 1
              ELSE #{requested_offset + 1}
            END AS first_row,
            total
          FROM catalog_totals
        )
        SELECT
          0 AS result_order,
          -1 AS kind,
          0 AS record_id,
          0 AS audible_tag,
          total,
          CAST((first_row - 1) / #{CATALOG_ITEMS_PER_PAGE} AS INTEGER) + 1 AS catalog_page
        FROM page_bounds
        UNION ALL
        SELECT
          numbered_entries.catalog_row + 1 AS result_order,
          numbered_entries.kind,
          numbered_entries.record_id,
          numbered_entries.audible_tag,
          page_bounds.total,
          CAST((page_bounds.first_row - 1) / #{CATALOG_ITEMS_PER_PAGE} AS INTEGER) + 1
            AS catalog_page
        FROM numbered_entries
        CROSS JOIN page_bounds
        WHERE numbered_entries.catalog_row BETWEEN page_bounds.first_row
          AND page_bounds.first_row + #{CATALOG_ITEMS_PER_PAGE - 1}
        ORDER BY result_order
      SQL
    end

    def dynamic_identifier_matches_sql
      if connection.adapter_name == "PostgreSQL"
        return "SELECT NULL::bigint AS owned_item_id, NULL::bigint AS matched_book_id WHERE 1=0" unless audible_catalog?
      else
        return "SELECT NULL AS owned_item_id, NULL AS matched_book_id WHERE 1=0" unless audible_catalog?
      end

      <<~SQL.squish
        SELECT
          normalized_owned_identifiers.owned_item_id,
          CASE WHEN COUNT(DISTINCT normalized_book_identifiers.book_id) = 1
            THEN MIN(normalized_book_identifiers.book_id)
          END AS matched_book_id
        FROM normalized_owned_identifiers
        INNER JOIN normalized_library_identifiers
          ON normalized_library_identifiers.asin_key = normalized_owned_identifiers.asin_key
        INNER JOIN normalized_book_identifiers
          ON normalized_book_identifiers.isbn_key = normalized_library_identifiers.isbn_key
        GROUP BY normalized_owned_identifiers.owned_item_id
      SQL
    end

    def normalized_library_identifiers_sql
      return empty_identifier_sql("asin_key", "isbn_key", "text", "text") unless audible_catalog?

      missing_condition = connection.adapter_name == "PostgreSQL" ? "library_items.missing = FALSE" : "library_items.missing = 0"

      <<~SQL.squish
        SELECT
          #{catalog_asin_sql('library_items.asin')} AS asin_key,
          #{catalog_isbn_sql('library_items.isbn')} AS isbn_key
        FROM library_items
        WHERE library_items.library_platform = #{quote(SettingsService.active_library_platform)}
          AND #{missing_condition}
          AND #{catalog_asin_sql('library_items.asin')} <> ''
          AND #{catalog_isbn_sql('library_items.isbn')} <> ''
      SQL
    end

    def normalized_book_identifiers_sql
      return empty_identifier_sql("book_id", "isbn_key", "bigint", "text") unless audible_catalog?

      <<~SQL.squish
        SELECT
          books.id AS book_id,
          #{catalog_isbn_sql('books.isbn')} AS isbn_key
        FROM books
        WHERE books.book_type = #{Book.book_types.fetch("audiobook")}
          AND books.file_path IS NOT NULL
          AND TRIM(books.file_path) <> ''
          AND #{catalog_isbn_sql('books.isbn')} <> ''
      SQL
    end

    def normalized_owned_identifiers_sql
      return empty_identifier_sql("owned_item_id", "asin_key", "bigint", "text") unless audible_catalog?

      <<~SQL.squish
        SELECT
          owned_library_items.id AS owned_item_id,
          #{catalog_asin_sql('owned_library_items.external_id')} AS asin_key
        FROM owned_library_items
        LEFT JOIN books AS linked_books ON linked_books.id = owned_library_items.book_id
        WHERE #{visible_owned_item_sql}
          AND #{catalog_asin_sql('owned_library_items.external_id')} <> ''
      SQL
    end

    def empty_identifier_sql(first_column, second_column, type1 = "bigint", type2 = "bigint")
      if connection.adapter_name == "PostgreSQL"
        "SELECT NULL::#{type1} AS #{first_column}, NULL::#{type2} AS #{second_column} WHERE 1=0"
      else
        "SELECT NULL AS #{first_column}, NULL AS #{second_column} WHERE 1=0"
      end
    end

    def raw_book_entries_sql
      <<~SQL.squish
        SELECT
          0 AS kind,
          books.id AS record_id,
          COALESCE(books.title, '') AS title,
          COALESCE(books.author, '') AS author,
          CASE WHEN audible_book_tags.book_id IS NULL THEN 0 ELSE 1 END AS audible_tag,
          CASE WHEN dynamic_book_search_matches.book_id IS NULL THEN 0 ELSE 1 END
            AS dynamic_search_match
        FROM books
        LEFT JOIN audible_book_tags ON audible_book_tags.book_id = books.id
        LEFT JOIN dynamic_book_search_matches
          ON dynamic_book_search_matches.book_id = books.id
        WHERE books.file_path IS NOT NULL
          AND TRIM(books.file_path) <> ''
          #{book_type_sql}
      SQL
    end

    def book_filter_sql
      filters = []
      filters << "audible_tag = 1" if source_filter == "audible"
      if query.present?
        filters << <<~SQL.squish
          (
            #{catalog_lower_sql('title')} LIKE #{query_pattern} ESCAPE '\\'
            OR #{catalog_lower_sql('author')} LIKE #{query_pattern} ESCAPE '\\'
            OR dynamic_search_match = 1
          )
        SQL
      end
      filters.presence&.join(" AND ") || "1 = 1"
    end

    def audible_book_tags_sql
      active_condition = connection.adapter_name == "PostgreSQL" ? "tagged_items.active = TRUE" : "tagged_items.active = 1"
      <<~SQL.squish
        SELECT tagged_items.book_id
        FROM owned_library_items AS tagged_items
        INNER JOIN owned_library_connections
          ON owned_library_connections.id = tagged_items.owned_library_connection_id
        WHERE tagged_items.book_id IS NOT NULL
          AND #{active_condition}
          AND tagged_items.ownership_type = 'purchased'
          AND tagged_items.media_type = 'audiobook'
          AND owned_library_connections.provider = 'libation'
        UNION
        SELECT matched_book_id AS book_id
        FROM dynamic_identifier_matches
        WHERE matched_book_id IS NOT NULL
      SQL
    end

    def dynamic_book_search_matches_sql
      if connection.adapter_name == "PostgreSQL"
        return "SELECT NULL::bigint AS book_id WHERE 1=0" unless audible_catalog? && query.present?
      else
        return "SELECT NULL AS book_id WHERE 1=0" unless audible_catalog? && query.present?
      end

      <<~SQL.squish
        SELECT DISTINCT dynamic_identifier_matches.matched_book_id AS book_id
        FROM dynamic_identifier_matches
        INNER JOIN owned_library_items AS matched_items
          ON matched_items.id = dynamic_identifier_matches.owned_item_id
        WHERE dynamic_identifier_matches.matched_book_id IS NOT NULL
          AND (
            #{catalog_lower_sql(owned_display_title_sql("matched_items"))}
              LIKE #{query_pattern} ESCAPE '\\'
            OR #{catalog_lower_sql(owned_author_sql("matched_items"))}
              LIKE #{query_pattern} ESCAPE '\\'
          )
      SQL
    end

    def owned_entries_sql
      unless audible_catalog?
        if connection.adapter_name == "PostgreSQL"
          return <<~SQL.squish
            SELECT NULL::integer AS kind, NULL::bigint AS record_id, NULL::text AS title, NULL::text AS author,
              NULL::integer AS audible_tag WHERE 1=0
          SQL
        else
          return <<~SQL.squish
            SELECT NULL AS kind, NULL AS record_id, NULL AS title, NULL AS author,
              NULL AS audible_tag WHERE 1=0
          SQL
        end
      end

      filters = [
        visible_owned_item_sql,
        "dynamic_identifier_matches.matched_book_id IS NULL"
      ]
      if query.present?
        filters << <<~SQL.squish
          (
            #{catalog_lower_sql(owned_display_title_sql)}
              LIKE #{query_pattern} ESCAPE '\\'
            OR #{catalog_lower_sql(owned_author_sql)}
              LIKE #{query_pattern} ESCAPE '\\'
          )
        SQL
      end

      <<~SQL.squish
        SELECT
          1 AS kind,
          owned_library_items.id AS record_id,
          #{owned_display_title_sql} AS title,
          #{owned_author_sql} AS author,
          1 AS audible_tag
        FROM owned_library_items
        LEFT JOIN books AS linked_books ON linked_books.id = owned_library_items.book_id
        LEFT JOIN dynamic_identifier_matches
          ON dynamic_identifier_matches.owned_item_id = owned_library_items.id
        WHERE #{filters.join(" AND ")}
      SQL
    end

    def visible_owned_item_sql
      active_condition = connection.adapter_name == "PostgreSQL" ? "owned_library_items.active = TRUE" : "owned_library_items.active = 1"
      <<~SQL.squish
        owned_library_items.owned_library_connection_id = #{owned_library_connection.id.to_i}
          AND #{active_condition}
          AND owned_library_items.ownership_type = 'purchased'
          AND owned_library_items.media_type = 'audiobook'
          AND (
            linked_books.id IS NULL
            OR linked_books.file_path IS NULL
            OR TRIM(linked_books.file_path) = ''
          )
      SQL
    end

    def owned_display_title_sql(table = "owned_library_items")
      <<~SQL.squish
        CASE
          WHEN #{table}.subtitle IS NOT NULL AND TRIM(#{table}.subtitle) <> ''
            THEN #{table}.title || ': ' || #{table}.subtitle
          ELSE #{table}.title
        END
      SQL
    end

    def owned_author_sql(table = "owned_library_items")
      if connection.adapter_name == "PostgreSQL"
        <<~SQL.squish
          COALESCE(
            (
              SELECT STRING_AGG(author, ', ')
              FROM (
                SELECT json_array_elements_text(#{table}.authors::json) AS author
              ) AS subquery
              WHERE TRIM(author) <> ''
            ),
            ''
          )
        SQL
      else
        <<~SQL.squish
          COALESCE(
            (
              SELECT GROUP_CONCAT(CAST(author.value AS TEXT), ', ')
              FROM JSON_EACH(#{table}.authors) AS author
              WHERE TRIM(CAST(author.value AS TEXT)) <> ''
            ),
            ''
          )
        SQL
      end
    end

    def catalog_lower_sql(column)
      if connection.adapter_name == "PostgreSQL"
        "LOWER(CAST(#{column} AS TEXT))"
      else
        "shelfarr_catalog_lower(#{column})"
      end
    end

    def catalog_asin_sql(column)
      if connection.adapter_name == "PostgreSQL"
        "REGEXP_REPLACE(UPPER(CAST(#{column} AS TEXT)), '[^A-Z0-9]', '', 'g')"
      else
        "shelfarr_catalog_asin(#{column})"
      end
    end

    def catalog_isbn_sql(column)
      if connection.adapter_name == "PostgreSQL"
        "REGEXP_REPLACE(UPPER(CAST(#{column} AS TEXT)), '[^0-9X]', '', 'g')"
      else
        "shelfarr_catalog_isbn(#{column})"
      end
    end

    def book_type_sql
      return "" unless type_filter

      "AND books.book_type = #{Book.book_types.fetch(type_filter)}"
    end

    def audible_catalog?
      owned_library_connection.present? && type_filter.in?([ nil, "audiobook" ])
    end

    def requested_offset
      (requested_page - 1) * CATALOG_ITEMS_PER_PAGE
    end

    def query_pattern
      @query_pattern ||= quote(
        "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
      )
    end

    def quote(value)
      connection.quote(value)
    end

    def connection
      ActiveRecord::Base.connection
    end

    def projection(row)
      Projection.new(
        kind: row.fetch("kind").to_i.zero? ? :book : :audible,
        id: row.fetch("record_id").to_i,
        audible_tag: row.fetch("audible_tag").to_i == 1
      )
    end

    def register_sqlite_functions!
      database = connection.raw_connection
      define_function(database, "shelfarr_catalog_lower") { |value| value.to_s.downcase }
      define_function(database, "shelfarr_catalog_asin") do |value|
        value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      end
      define_function(database, "shelfarr_catalog_isbn") do |value|
        value.to_s.upcase.gsub(/[^0-9X]/, "")
      end
      define_function(database, "shelfarr_catalog_text") do |value|
        value.to_s
          .unicode_normalize(:nfkd)
          .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
          .downcase
          .gsub(/[^a-z0-9\s]/, " ")
          .gsub(/\s+/, " ")
          .strip
      end
    end

    def define_function(database, name, &block)
      database.create_function(name, 1) do |function, value|
        function.result = block.call(value)
      end
    end
  end

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @query = params[:q].to_s.strip.first(200)
    @type_filter = params[:type].presence_in(Book.book_types.keys)
    @source_filter = params[:source].presence_in(SOURCE_FILTERS)
    load_owned_audible_items
    no_store if @owned_library_connection
    build_catalog
  end

  def show
    @book = Book.acquired.find(params[:id])
    @user_request = @book.requests.completed.first
    @attention_request = @book.requests.where(attention_needed: true).first
  end

  def retry_post_processing
    unless Current.user&.admin?
      redirect_to library_index_path, alert: "Only admins can retry post-processing"
      return
    end

    @book = Book.find(params[:id])
    request = @book.requests.where(attention_needed: true).first
    download = request&.downloads&.where(status: :completed)&.order(created_at: :desc)&.first

    unless request && download
      redirect_to library_path(@book), alert: "No retryable post-processing found for this book"
      return
    end

    outcome = request.retry_post_processing_now!
    case outcome
    when :post_processing_queued
      redirect_to library_path(@book), notice: "Post-processing has been queued for retry."
    when :post_processing_recovery_pending
      redirect_to library_path(@book),
        alert: "The immediate post-processing retry could not be queued. " \
          "Its durable recovery claim was kept and the watchdog will retry it automatically."
    when :active
      redirect_to library_path(@book), notice: "Post-processing recovery is already active."
    when :superseded
      redirect_to library_path(@book), notice: "Another post-processing recovery attempt took ownership."
    else
      redirect_to library_path(@book), alert: "No retryable post-processing found for this book"
    end
  end

  def destroy
    unless Current.user.admin?
      redirect_to library_index_path, alert: "Only admins can delete books from the library"
      return
    end

    @book = Book.find(params[:id])

    if acquisition_recovery_pending?(@book)
      redirect_to library_path(@book),
        alert: "This book has an upload or direct acquisition in progress, " \
          "or a post-processing import awaiting recovery. " \
          "Wait for it to finish, or retry its recovery, before removing the library record."
      return
    end

    # Optionally remove torrents from download clients
    if params[:remove_torrent] == "1"
      remove_associated_torrents(@book)
    end

    # Delete book files from disk if requested.
    # Also asks the active library platform to remove its item if supported.
    if params[:delete_files] == "1" && @book.file_path.present?
      unless delete_book_files(@book)
        redirect_to library_path(@book),
          alert: "Shelfarr could not safely remove this book's files. The library record was kept."
        return
      end
      delete_from_library_platform(@book)
    end

    Book.transaction do
      # Keep request deletion and the Book restriction in one database
      # transaction. A model-level acquisition guard which wins a race with
      # the preflight below then rolls every record deletion back together.
      ActivityTracker.track("book.deleted", trackable: @book, user: Current.user)
      @book.requests.find_each(&:destroy!)
      @book.requests.reset
      @book.destroy!
    end

    redirect_to library_index_path, notice: "\"#{@book.title}\" has been removed from the library"
  rescue ActiveRecord::RecordNotDestroyed => error
    Rails.logger.warn(
      "[LibraryController] Refused blocked library deletion for Book ##{@book&.id}: " \
        "#{error.class}"
    )
    redirect_to library_path(@book),
      alert: "This book could not be removed because an upload, post-processing import, " \
        "or acquisition recovery is still in progress. " \
        "Retry the recovery and try again."
  end

  private

  def acquisition_recovery_pending?(book)
    return true if book.owned_media_recovery_pending?
    return true if book.post_processing_recovery_pending?

    book.requests.any? do |request|
      request.upload_cancellation_blocked? ||
        request.post_processing_recovery_pending? ||
        request.direct_acquisition_recovery_pending?
    end
  end

  def load_owned_audible_items
    @owned_library_connection = if Current.user&.admin?
      OwnedLibraryConnection.enabled.for_provider("libation").first
    end
    @show_audible_controls = @owned_library_connection.present? &&
      @type_filter.in?([ nil, "audiobook" ])
    @owned_backup_counts = if @owned_library_connection
      @owned_library_connection.owned_media_imports
        .where(status: [ "pending", *OwnedMediaImport::ACTIVE_STATUSES ])
        .group(:status)
        .count
    else
      {}
    end
    @owned_backup_total = @owned_backup_counts.values.sum
  end

  def build_catalog
    result = CatalogQuery.new(
      query: @query,
      type_filter: @type_filter,
      source_filter: @source_filter,
      owned_library_connection: (@owned_library_connection if @show_audible_controls),
      page: params[:page]
    ).call

    @total_titles = result.total
    @catalog_total_pages = [ (@total_titles.to_f / CATALOG_ITEMS_PER_PAGE).ceil, 1 ].max
    @catalog_page = result.page
    hydrate_catalog_page(result.entries)
  end

  def hydrate_catalog_page(projections)
    book_ids = projections.select { |entry| entry.kind == :book }.map(&:id)
    owned_item_ids = projections.reject { |entry| entry.kind == :book }.map(&:id)
    books_by_id = Book.where(id: book_ids).index_by(&:id)
    owned_items_by_id = OwnedLibraryItem
      .includes(:owned_library_connection)
      .where(id: owned_item_ids)
      .index_by(&:id)
    OwnedLibraryItem.preload_latest_imports(owned_items_by_id.values)

    @catalog_entries = projections.filter_map do |projection|
      records = projection.kind == :book ? books_by_id : owned_items_by_id
      record = records[projection.id]
      CatalogEntry.new(kind: projection.kind, record: record) if record
    end
    @audible_tagged_book_ids = Set.new(
      projections.select { |entry| entry.kind == :book && entry.audible_tag }.map(&:id)
    )
    visible_owned_items = owned_item_ids.filter_map { |id| owned_items_by_id[id] }
    @owned_library_resolutions = resolve_visible_owned_items(visible_owned_items)
  end

  def resolve_visible_owned_items(items)
    return {} if items.empty?

    title_keys = items.flat_map { |item| [ item.title, item.display_title ] }
      .filter_map { |title| normalize_catalog_text(title).presence }
      .uniq
    asin_keys = items.filter_map { |item| normalize_catalog_asin(item.external_id).presence }.uniq

    asin_sql = if LibraryItem.connection.adapter_name == "PostgreSQL"
      "REGEXP_REPLACE(UPPER(CAST(asin AS TEXT)), '[^A-Z0-9]', '', 'g')"
    else
      "shelfarr_catalog_asin(asin)"
    end

    library_items = LibraryItem.available_for_matching.where(
      "#{asin_sql} IN (?)",
      asin_keys
    ).select(:asin, :isbn).to_a
    isbn_keys = library_items.filter_map { |item| normalize_catalog_isbn(item.isbn).presence }.uniq
    book_filters = []

    text_sql = if Book.connection.adapter_name == "PostgreSQL"
      "REGEXP_REPLACE(LOWER(CAST(title AS TEXT)), '[^a-z0-9\\s]', ' ', 'g')"
    else
      "shelfarr_catalog_text(title)"
    end

    book_filters << Book.acquired.audiobooks.where(
      "#{text_sql} IN (?)",
      title_keys
    ) if title_keys.any?

    isbn_sql = if Book.connection.adapter_name == "PostgreSQL"
      "REGEXP_REPLACE(UPPER(CAST(isbn AS TEXT)), '[^0-9X]', '', 'g')"
    else
      "shelfarr_catalog_isbn(isbn)"
    end

    book_filters << Book.acquired.audiobooks.where(
      "#{isbn_sql} IN (?)",
      isbn_keys
    ) if isbn_keys.any?
    books = book_filters.reduce(Book.none) { |scope, filter| scope.or(filter) }
      .select(:id, :title, :author, :narrator, :isbn, :book_type, :file_path)
      .to_a
    OwnedLibraryBookMatcher.new(books: books, library_items: library_items).resolve_many(items)
  end

  def normalize_catalog_text(value)
    value.to_s
      .unicode_normalize(:nfkd)
      .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
      .downcase
      .gsub(/[^a-z0-9\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
  end

  def normalize_catalog_asin(value)
    value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def normalize_catalog_isbn(value)
    value.to_s.upcase.gsub(/[^0-9X]/, "")
  end

  def record_not_found
    head :not_found
  end

  def remove_associated_torrents(book)
    book.requests.each do |request|
      request.downloads.each do |download|
        next unless download.external_id.present? && download.download_client.present?

        begin
          client = download.download_client.adapter
          client.remove_torrent(download.external_id, delete_files: false)
          Rails.logger.info "[LibraryController] Removed torrent for download ##{download.id}"
        rescue DownloadClients::Base::Error => e
          Rails.logger.warn(
            "[LibraryController] Failed to remove torrent for download ##{download.id}: #{e.class}"
          )
        end
      end
    end
  end

  def delete_book_files(book)
    SafeLibraryDeletionService.new(book).delete!
    Rails.logger.info "[LibraryController] Safely deleted library path for book ##{book.id}"
    true
  rescue SafeLibraryDeletionService::Error => error
    Rails.logger.error "[LibraryController] Failed to delete files for book ##{book.id}: #{error.class}"
    false
  end

  def delete_from_library_platform(book)
    return unless LibraryPlatformClient.configured?
    return unless book.file_path.present?

    if LibraryPlatformClient.delete_item_by_path(book.file_path)
      Rails.logger.info(
        "[LibraryController] Deleted book ##{book.id} from #{LibraryPlatformClient.display_name}"
      )
    else
      Rails.logger.warn(
        "[LibraryController] Book ##{book.id} was not found in #{LibraryPlatformClient.display_name}"
      )
    end
  rescue LibraryPlatformClient::Error => e
    Rails.logger.error(
      "[LibraryController] Failed to delete book ##{book.id} from " \
        "#{LibraryPlatformClient.display_name}: #{e.class}"
    )
  end
end
