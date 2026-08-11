# frozen_string_literal: true

require "set"

class LibraryController < ApplicationController
  CATALOG_ITEMS_PER_PAGE = 50
  AUDIBLE_SOURCE_FILTER = "audible"

  CatalogEntry = Data.define(:kind, :record) do
    def book?
      kind == :book
    end

    def synced?
      kind == :synced
    end
  end

  # The catalog is a projection over multiple tables, not an Active Record relation.
  # Keep the merge, filtering, stable ordering, count, and page clamp inside one
  # SQLite query so a page render never materializes the rest of the library.
  class CatalogQuery
    MAX_REQUESTED_PAGE = 1_000_000_000
    Projection = Data.define(:kind, :id, :audible_tag, :synced_tag)
    Result = Data.define(:entries, :total, :page)

    def initialize(query:, type_filter:, source_filter:, owned_library_connection:,
      active_library_platform:, page:)
      @query = query
      @type_filter = type_filter
      @source_filter = source_filter
      @owned_library_connection = owned_library_connection
      @active_library_platform = active_library_platform
      @requested_page = page.to_i.clamp(1, MAX_REQUESTED_PAGE)
    end

    def call
      register_sqlite_functions!
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
      :active_library_platform, :requested_page

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
        normalized_synced_catalog_items AS MATERIALIZED (
          #{normalized_synced_catalog_items_sql}
        ),
        external_synced_item_groups AS MATERIALIZED (
          #{external_synced_item_groups_sql}
        ),
        representative_synced_items AS MATERIALIZED (
          #{representative_synced_items_sql}
        ),
        canonical_synced_representatives AS MATERIALIZED (
          #{canonical_synced_representatives_sql}
        ),
        canonical_synced_item_groups AS MATERIALIZED (
          #{canonical_synced_item_groups_sql}
        ),
        normalized_catalog_books AS MATERIALIZED (
          #{normalized_catalog_books_sql}
        ),
        synced_book_candidates AS MATERIALIZED (
          #{synced_book_candidates_sql}
        ),
        canonical_synced_book_matches AS MATERIALIZED (
          #{canonical_synced_book_matches_sql}
        ),
        synced_item_search_matches AS MATERIALIZED (
          #{synced_item_search_matches_sql}
        ),
        synced_book_search_matches AS MATERIALIZED (
          #{synced_book_search_matches_sql}
        ),
        synced_book_tags AS MATERIALIZED (
          #{synced_book_tags_sql}
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
          SELECT kind, record_id, title, author, audible_tag, synced_tag
          FROM raw_book_entries
          WHERE #{book_filter_sql}
        ),
        owned_entries AS (
          #{owned_entries_sql}
        ),
        synced_entries AS (
          #{synced_entries_sql}
        ),
        catalog_entries AS MATERIALIZED (
          SELECT * FROM book_entries
          UNION ALL
          SELECT * FROM owned_entries
          UNION ALL
          SELECT * FROM synced_entries
        ),
        numbered_entries AS MATERIALIZED (
          SELECT
            kind,
            record_id,
            audible_tag,
            synced_tag,
            ROW_NUMBER() OVER (
              ORDER BY shelfarr_catalog_lower(title),
                shelfarr_catalog_lower(author), kind, record_id
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
          0 AS synced_tag,
          total,
          CAST((first_row - 1) / #{CATALOG_ITEMS_PER_PAGE} AS INTEGER) + 1 AS catalog_page
        FROM page_bounds
        UNION ALL
        SELECT
          numbered_entries.catalog_row + 1 AS result_order,
          numbered_entries.kind,
          numbered_entries.record_id,
          numbered_entries.audible_tag,
          numbered_entries.synced_tag,
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
      return "SELECT NULL AS owned_item_id, NULL AS matched_book_id WHERE 0" unless audible_catalog?

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

    # Collapse a synced item only for a unique ISBN match, or for exact
    # title/author metadata when the format is known and ISBNs do not conflict.
    def normalized_synced_catalog_items_sql
      <<~SQL.squish
        SELECT
          synced_items.id AS library_item_id,
          synced_items.audiobookshelf_id AS external_id,
          synced_items.book_type,
          #{synced_book_type_case_sql("synced_items")} AS book_type_value,
          shelfarr_catalog_valid_isbn(synced_items.isbn) AS isbn_key,
          shelfarr_catalog_text(synced_items.title) AS title_key,
          shelfarr_catalog_text(synced_items.author) AS author_key
        FROM library_items AS synced_items
        WHERE #{visible_synced_item_sql("synced_items")}
      SQL
    end

    def external_synced_item_groups_sql
      <<~SQL.squish
        SELECT
          external_id,
          COALESCE(
            MIN(CASE WHEN isbn_key <> '' AND book_type = 'ebook_or_comic'
              THEN library_item_id END),
            MIN(CASE WHEN isbn_key <> '' AND book_type IS NOT NULL
              THEN library_item_id END),
            MIN(CASE WHEN book_type = 'ebook_or_comic' THEN library_item_id END),
            MIN(CASE WHEN book_type IS NOT NULL THEN library_item_id END),
            MIN(CASE WHEN isbn_key <> '' THEN library_item_id END),
            MIN(library_item_id)
          ) AS representative_library_item_id
        FROM normalized_synced_catalog_items
        GROUP BY external_id
      SQL
    end

    def representative_synced_items_sql
      <<~SQL.squish
        SELECT
          selected_items.library_item_id,
          selected_items.external_id,
          selected_items.book_type,
          selected_items.book_type_value,
          CASE WHEN COUNT(DISTINCT NULLIF(group_items.isbn_key, '')) = 1
            THEN MAX(group_items.isbn_key)
            ELSE ''
          END AS isbn_key,
          selected_items.title_key,
          selected_items.author_key
        FROM normalized_synced_catalog_items AS selected_items
        INNER JOIN external_synced_item_groups
          ON external_synced_item_groups.representative_library_item_id =
            selected_items.library_item_id
        INNER JOIN normalized_synced_catalog_items AS group_items
          ON group_items.external_id = selected_items.external_id
        GROUP BY selected_items.library_item_id
      SQL
    end

    def canonical_synced_representatives_sql
      <<~SQL.squish
        SELECT
          library_item_id,
          CASE WHEN isbn_key <> ''
            THEN MIN(library_item_id) OVER (PARTITION BY isbn_key, book_type)
            ELSE library_item_id
          END AS canonical_library_item_id
        FROM representative_synced_items
      SQL
    end

    def canonical_synced_item_groups_sql
      <<~SQL.squish
        SELECT
          synced_items.library_item_id,
          canonical_synced_representatives.canonical_library_item_id
        FROM normalized_synced_catalog_items AS synced_items
        INNER JOIN external_synced_item_groups
          ON external_synced_item_groups.external_id = synced_items.external_id
        INNER JOIN canonical_synced_representatives
          ON canonical_synced_representatives.library_item_id =
            external_synced_item_groups.representative_library_item_id
      SQL
    end

    def normalized_catalog_books_sql
      <<~SQL.squish
        SELECT
          books.id AS book_id,
          books.book_type,
          shelfarr_catalog_valid_isbn(books.isbn) AS isbn_key,
          shelfarr_catalog_text(books.title) AS title_key,
          shelfarr_catalog_text(books.author) AS author_key
        FROM books
        WHERE books.file_path IS NOT NULL
          AND TRIM(books.file_path) <> ''
      SQL
    end

    def synced_book_candidates_sql
      <<~SQL.squish
        SELECT synced_items.library_item_id, catalog_books.book_id
        FROM normalized_synced_catalog_items AS synced_items
        INNER JOIN normalized_catalog_books AS catalog_books
          ON synced_items.isbn_key <> ''
          AND synced_items.isbn_key = catalog_books.isbn_key
          AND #{synced_book_type_match_sql}
        UNION ALL
        SELECT synced_items.library_item_id, catalog_books.book_id
        FROM normalized_synced_catalog_items AS synced_items
        INNER JOIN normalized_catalog_books AS catalog_books
          ON synced_items.book_type IS NOT NULL
          AND #{synced_book_type_match_sql}
          AND (synced_items.isbn_key = '' OR catalog_books.isbn_key = '')
          AND synced_items.title_key <> ''
          AND synced_items.title_key = catalog_books.title_key
          AND synced_items.author_key <> ''
          AND synced_items.author_key = catalog_books.author_key
      SQL
    end

    def synced_book_type_match_sql
      <<~SQL.squish
        (
          synced_items.book_type IS NULL
          OR synced_items.book_type_value = catalog_books.book_type
          OR (
            synced_items.book_type = 'ebook_or_comic'
            AND catalog_books.book_type IN (
              #{Book.book_types.fetch("ebook")},
              #{Book.book_types.fetch("comicbook")}
            )
          )
        )
      SQL
    end

    def canonical_synced_book_matches_sql
      <<~SQL.squish
        SELECT
          canonical_synced_item_groups.canonical_library_item_id AS library_item_id,
          CASE WHEN COUNT(DISTINCT synced_book_candidates.book_id) = 1
            THEN MIN(synced_book_candidates.book_id)
          END AS matched_book_id
        FROM canonical_synced_item_groups
        INNER JOIN synced_book_candidates
          ON synced_book_candidates.library_item_id =
            canonical_synced_item_groups.library_item_id
        GROUP BY canonical_synced_item_groups.canonical_library_item_id
      SQL
    end

    def synced_item_search_matches_sql
      return "SELECT NULL AS library_item_id WHERE 0" unless query.present?

      <<~SQL.squish
        SELECT DISTINCT
          canonical_synced_item_groups.canonical_library_item_id AS library_item_id
        FROM canonical_synced_item_groups
        INNER JOIN library_items
          ON library_items.id = canonical_synced_item_groups.library_item_id
        WHERE
          shelfarr_catalog_lower(#{synced_display_title_sql})
            LIKE #{query_pattern} ESCAPE '\\'
          OR shelfarr_catalog_lower(COALESCE(library_items.author, ''))
            LIKE #{query_pattern} ESCAPE '\\'
      SQL
    end

    def synced_book_search_matches_sql
      return "SELECT NULL AS book_id WHERE 0" unless query.present?

      <<~SQL.squish
        SELECT DISTINCT canonical_synced_book_matches.matched_book_id AS book_id
        FROM canonical_synced_book_matches
        INNER JOIN canonical_synced_item_groups
          ON canonical_synced_item_groups.canonical_library_item_id =
            canonical_synced_book_matches.library_item_id
        INNER JOIN library_items
          ON library_items.id = canonical_synced_item_groups.library_item_id
        WHERE canonical_synced_book_matches.matched_book_id IS NOT NULL
          AND (
            shelfarr_catalog_lower(#{synced_display_title_sql})
              LIKE #{query_pattern} ESCAPE '\\'
            OR shelfarr_catalog_lower(COALESCE(library_items.author, ''))
              LIKE #{query_pattern} ESCAPE '\\'
          )
      SQL
    end

    def synced_book_tags_sql
      <<~SQL.squish
        SELECT matched_book_id AS book_id
        FROM canonical_synced_book_matches
        WHERE matched_book_id IS NOT NULL
        GROUP BY matched_book_id
      SQL
    end

    def synced_book_type_case_sql(table)
      <<~SQL.squish
        CASE #{table}.book_type
          WHEN 'audiobook' THEN #{Book.book_types.fetch("audiobook")}
          WHEN 'ebook' THEN #{Book.book_types.fetch("ebook")}
          WHEN 'comicbook' THEN #{Book.book_types.fetch("comicbook")}
        END
      SQL
    end

    def normalized_library_identifiers_sql
      return empty_identifier_sql("asin_key", "isbn_key") unless audible_catalog?

      <<~SQL.squish
        SELECT
          shelfarr_catalog_asin(library_items.asin) AS asin_key,
          shelfarr_catalog_isbn(library_items.isbn) AS isbn_key
        FROM library_items
        WHERE library_items.library_platform = #{quote(active_library_platform)}
          AND library_items.missing = 0
          AND shelfarr_catalog_asin(library_items.asin) <> ''
          AND shelfarr_catalog_isbn(library_items.isbn) <> ''
      SQL
    end

    def normalized_book_identifiers_sql
      return empty_identifier_sql("book_id", "isbn_key") unless audible_catalog?

      <<~SQL.squish
        SELECT
          books.id AS book_id,
          shelfarr_catalog_isbn(books.isbn) AS isbn_key
        FROM books
        WHERE books.book_type = #{Book.book_types.fetch("audiobook")}
          AND books.file_path IS NOT NULL
          AND TRIM(books.file_path) <> ''
          AND shelfarr_catalog_isbn(books.isbn) <> ''
      SQL
    end

    def normalized_owned_identifiers_sql
      return empty_identifier_sql("owned_item_id", "asin_key") unless audible_catalog?

      <<~SQL.squish
        SELECT
          owned_library_items.id AS owned_item_id,
          shelfarr_catalog_asin(owned_library_items.external_id) AS asin_key
        FROM owned_library_items
        LEFT JOIN books AS linked_books ON linked_books.id = owned_library_items.book_id
        WHERE #{visible_owned_item_sql}
          AND shelfarr_catalog_asin(owned_library_items.external_id) <> ''
      SQL
    end

    def empty_identifier_sql(first_column, second_column)
      "SELECT NULL AS #{first_column}, NULL AS #{second_column} WHERE 0"
    end

    def raw_book_entries_sql
      <<~SQL.squish
        SELECT
          0 AS kind,
          books.id AS record_id,
          COALESCE(books.title, '') AS title,
          COALESCE(books.author, '') AS author,
          CASE WHEN audible_book_tags.book_id IS NULL THEN 0 ELSE 1 END AS audible_tag,
          CASE WHEN synced_book_tags.book_id IS NULL THEN 0 ELSE 1 END AS synced_tag,
          CASE WHEN synced_book_search_matches.book_id IS NULL THEN 0 ELSE 1 END
            AS synced_search_match,
          CASE WHEN dynamic_book_search_matches.book_id IS NULL THEN 0 ELSE 1 END
            AS dynamic_search_match
        FROM books
        LEFT JOIN audible_book_tags ON audible_book_tags.book_id = books.id
        LEFT JOIN synced_book_tags ON synced_book_tags.book_id = books.id
        LEFT JOIN synced_book_search_matches
          ON synced_book_search_matches.book_id = books.id
        LEFT JOIN dynamic_book_search_matches
          ON dynamic_book_search_matches.book_id = books.id
        WHERE books.file_path IS NOT NULL
          AND TRIM(books.file_path) <> ''
          #{book_type_sql}
      SQL
    end

    def book_filter_sql
      filters = []
      if source_filter == AUDIBLE_SOURCE_FILTER
        filters << "audible_tag = 1"
      elsif synced_source_filter?
        filters << "synced_tag = 1"
      end
      if query.present?
        filters << <<~SQL.squish
          (
            shelfarr_catalog_lower(title) LIKE #{query_pattern} ESCAPE '\\'
            OR shelfarr_catalog_lower(author) LIKE #{query_pattern} ESCAPE '\\'
            OR synced_search_match = 1
            OR dynamic_search_match = 1
          )
        SQL
      end
      filters.presence&.join(" AND ") || "1 = 1"
    end

    def audible_book_tags_sql
      <<~SQL.squish
        SELECT tagged_items.book_id
        FROM owned_library_items AS tagged_items
        INNER JOIN owned_library_connections
          ON owned_library_connections.id = tagged_items.owned_library_connection_id
        WHERE tagged_items.book_id IS NOT NULL
          AND tagged_items.active = 1
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
      return "SELECT NULL AS book_id WHERE 0" unless audible_catalog? && query.present?

      <<~SQL.squish
        SELECT DISTINCT dynamic_identifier_matches.matched_book_id AS book_id
        FROM dynamic_identifier_matches
        INNER JOIN owned_library_items AS matched_items
          ON matched_items.id = dynamic_identifier_matches.owned_item_id
        WHERE dynamic_identifier_matches.matched_book_id IS NOT NULL
          AND (
            shelfarr_catalog_lower(#{owned_display_title_sql("matched_items")})
              LIKE #{query_pattern} ESCAPE '\\'
            OR shelfarr_catalog_lower(#{owned_author_sql("matched_items")})
              LIKE #{query_pattern} ESCAPE '\\'
          )
      SQL
    end

    def owned_entries_sql
      return empty_catalog_entries_sql unless audible_catalog?
      return empty_catalog_entries_sql if synced_source_filter?

      filters = [
        visible_owned_item_sql,
        "dynamic_identifier_matches.matched_book_id IS NULL"
      ]
      if query.present?
        filters << <<~SQL.squish
          (
            shelfarr_catalog_lower(#{owned_display_title_sql})
              LIKE #{query_pattern} ESCAPE '\\'
            OR shelfarr_catalog_lower(#{owned_author_sql})
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
          1 AS audible_tag,
          0 AS synced_tag
        FROM owned_library_items
        LEFT JOIN books AS linked_books ON linked_books.id = owned_library_items.book_id
        LEFT JOIN dynamic_identifier_matches
          ON dynamic_identifier_matches.owned_item_id = owned_library_items.id
        WHERE #{filters.join(" AND ")}
      SQL
    end

    def synced_entries_sql
      return empty_catalog_entries_sql if source_filter == AUDIBLE_SOURCE_FILTER

      filters = [
        visible_synced_item_sql,
        "canonical_synced_book_matches.matched_book_id IS NULL"
      ]
      filters << synced_type_filter_sql if type_filter
      filters << "synced_item_search_matches.library_item_id IS NOT NULL" if query.present?

      <<~SQL.squish
        SELECT
          2 AS kind,
          library_items.id AS record_id,
          #{synced_display_title_sql} AS title,
          COALESCE(library_items.author, '') AS author,
          0 AS audible_tag,
          1 AS synced_tag
        FROM library_items
        INNER JOIN canonical_synced_item_groups
          ON canonical_synced_item_groups.library_item_id = library_items.id
          AND canonical_synced_item_groups.canonical_library_item_id = library_items.id
        LEFT JOIN canonical_synced_book_matches
          ON canonical_synced_book_matches.library_item_id = library_items.id
        LEFT JOIN synced_item_search_matches
          ON synced_item_search_matches.library_item_id = library_items.id
        WHERE #{filters.join(" AND ")}
      SQL
    end

    def synced_type_filter_sql
      if type_filter.in?(%w[ebook comicbook])
        "library_items.book_type IN (#{quote(type_filter)}, 'ebook_or_comic')"
      else
        "library_items.book_type = #{quote(type_filter)}"
      end
    end

    def empty_catalog_entries_sql
      <<~SQL.squish
        SELECT NULL AS kind, NULL AS record_id, NULL AS title, NULL AS author,
          NULL AS audible_tag, NULL AS synced_tag WHERE 0
      SQL
    end

    def synced_display_title_sql
      <<~SQL.squish
        CASE
          WHEN library_items.title IS NOT NULL AND TRIM(library_items.title) <> ''
            AND library_items.subtitle IS NOT NULL AND TRIM(library_items.subtitle) <> ''
            THEN library_items.title || ': ' || library_items.subtitle
          WHEN library_items.title IS NOT NULL AND TRIM(library_items.title) <> ''
            THEN library_items.title
          WHEN library_items.subtitle IS NOT NULL AND TRIM(library_items.subtitle) <> ''
            THEN library_items.subtitle
          ELSE 'Untitled'
        END
      SQL
    end

    def visible_synced_item_sql(table = "library_items")
      <<~SQL.squish
        #{table}.library_platform = #{quote(active_library_platform)}
          AND #{table}.missing = 0
      SQL
    end

    def visible_owned_item_sql
      <<~SQL.squish
        owned_library_items.owned_library_connection_id = #{owned_library_connection.id.to_i}
          AND owned_library_items.active = 1
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

    def book_type_sql
      return "" unless type_filter

      "AND books.book_type = #{Book.book_types.fetch(type_filter)}"
    end

    def audible_catalog?
      owned_library_connection.present? && type_filter.in?([ nil, "audiobook" ])
    end

    def synced_source_filter?
      source_filter == active_library_platform
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
      kind = case row.fetch("kind").to_i
      when 0 then :book
      when 1 then :audible
      else :synced
      end

      Projection.new(
        kind: kind,
        id: row.fetch("record_id").to_i,
        audible_tag: row.fetch("audible_tag").to_i == 1,
        synced_tag: row.fetch("synced_tag").to_i == 1
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
      define_function(database, "shelfarr_catalog_valid_isbn") do |value|
        valid_isbn_key(value)
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

    def valid_isbn_key(value)
      normalized = value.to_s.upcase.gsub(/[^0-9X]/, "")
      return normalized if valid_isbn_13?(normalized)
      return isbn_13_from_isbn_10(normalized) if valid_isbn_10?(normalized)

      ""
    end

    def isbn_13_from_isbn_10(isbn)
      base = "978#{isbn.first(9)}"
      check_digit = (10 - base.chars.each_with_index.sum do |digit, index|
        digit.to_i * (index.even? ? 1 : 3)
      end % 10) % 10
      "#{base}#{check_digit}"
    end

    def valid_isbn_10?(isbn)
      return false unless isbn.match?(/\A\d{9}[\dX]\z/)

      digits = isbn.chars.map { |character| character == "X" ? 10 : character.to_i }
      digits.each_with_index.sum { |digit, index| digit * (10 - index) } % 11 == 0
    end

    def valid_isbn_13?(isbn)
      return false unless isbn.match?(/\A\d{13}\z/)

      expected_check_digit = (10 - isbn.first(12).chars.each_with_index.sum do |digit, index|
        digit.to_i * (index.even? ? 1 : 3)
      end % 10) % 10
      isbn.last.to_i == expected_check_digit
    end
  end

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @query = params[:q].to_s.strip.first(200)
    @type_filter = params[:type].presence_in(Book.book_types.keys)
    load_synced_library_inventory
    @source_filter = params[:source].presence_in(
      [ AUDIBLE_SOURCE_FILTER, (@active_library_platform if @has_synced_library_items) ].compact
    )
    load_owned_audible_items
    no_store if @owned_library_connection || @has_synced_library_items
    build_catalog
  end

  def show
    @book = Book.acquired.find(params[:id])
    @user_request = @book.requests.completed.first
    @attention_request = @book.requests.where(attention_needed: true).first
  end

  def show_synced
    @library_item = LibraryItem.visible_in_library.find(params[:id])
    no_store
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

  def load_synced_library_inventory
    @active_library_platform = SettingsService.active_library_platform
    @has_synced_library_items = LibraryItem
      .for_platform(@active_library_platform)
      .where.not(missing: true)
      .exists?
  end

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
      active_library_platform: @active_library_platform,
      page: params[:page]
    ).call

    @total_titles = result.total
    @catalog_total_pages = [ (@total_titles.to_f / CATALOG_ITEMS_PER_PAGE).ceil, 1 ].max
    @catalog_page = result.page
    hydrate_catalog_page(result.entries)
  end

  def hydrate_catalog_page(projections)
    book_ids = projections.select { |entry| entry.kind == :book }.map(&:id)
    owned_item_ids = projections.select { |entry| entry.kind == :audible }.map(&:id)
    synced_item_ids = projections.select { |entry| entry.kind == :synced }.map(&:id)
    books_by_id = Book.where(id: book_ids).index_by(&:id)
    owned_items_by_id = OwnedLibraryItem
      .includes(:owned_library_connection)
      .where(id: owned_item_ids)
      .index_by(&:id)
    synced_items_by_id = LibraryItem.where(id: synced_item_ids).index_by(&:id)
    OwnedLibraryItem.preload_latest_imports(owned_items_by_id.values)

    @catalog_entries = projections.filter_map do |projection|
      records = case projection.kind
      when :book then books_by_id
      when :audible then owned_items_by_id
      else synced_items_by_id
      end
      record = records[projection.id]
      CatalogEntry.new(kind: projection.kind, record: record) if record
    end
    @audible_tagged_book_ids = Set.new(
      projections.select { |entry| entry.kind == :book && entry.audible_tag }.map(&:id)
    )
    @synced_library_book_ids = Set.new(
      projections.select { |entry| entry.kind == :book && entry.synced_tag }.map(&:id)
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
    library_items = LibraryItem.available_for_matching.where(
      "shelfarr_catalog_asin(asin) IN (?)",
      asin_keys
    ).select(:asin, :isbn).to_a
    isbn_keys = library_items.filter_map { |item| normalize_catalog_isbn(item.isbn).presence }.uniq
    book_filters = []
    book_filters << Book.acquired.audiobooks.where(
      "shelfarr_catalog_text(title) IN (?)",
      title_keys
    ) if title_keys.any?
    book_filters << Book.acquired.audiobooks.where(
      "shelfarr_catalog_isbn(isbn) IN (?)",
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
