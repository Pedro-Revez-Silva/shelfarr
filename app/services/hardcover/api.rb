# frozen_string_literal: true

module Hardcover
  # Typed reads over HardcoverClient for discovery, reading lists, and author
  # monitoring. Every method takes the credential to use so per-user tokens
  # and the instance token draw from the right Hardcover rate budget.
  module API
    PAGE_SIZE = 100
    WANT_TO_READ_STATUS_ID = 1
    TRENDING_DURATIONS = %w[week month three_month one_year all].freeze
    PRIMARY_ROLES = [ nil, "", "author", "writer", "co-author", "coauthor" ].freeze

    Account = Data.define(:id, :username)
    ListSummary = Data.define(:id, :name, :slug, :description, :books_count, :likes_count, :owner_username, :owner_id, :public) do
      def hardcover_url
        owner_username.present? && slug.present? ? "https://hardcover.app/@#{owner_username}/lists/#{slug}" : nil
      end
    end
    AuthorSummary = Data.define(:id, :name, :slug, :bio, :books_count, :image_url, :canonical_id, :top_titles) do
      def hardcover_url
        slug.present? ? "https://hardcover.app/authors/#{slug}" : nil
      end
    end

    # A Hardcover book, shaped so search/_result_card can render it.
    BookEntry = Data.define(
      :id, :title, :author, :author_ids, :description, :release_date, :release_year, :cover_url,
      :series_id, :series_name, :series_position, :users_count, :rating, :has_audiobook, :has_ebook,
      :compilation, :canonical_id, :created_at, :added_at, :position, :role, :languages
    ) do
      def work_id
        "hardcover:#{id}"
      end

      def first_publish_year
        release_year || release_date&.year
      end

      def source_name
        "Hardcover"
      end

      def source_url
        MetadataSources.hardcover_book_url(id)
      end

      def sources
        [ { source_name: source_name, source_url: source_url, work_id: work_id } ]
      end

      def content_kind
        ContentKinds::BOOK
      end

      def unreleased?(today = Date.current)
        release_date.present? && release_date > today
      end
    end

    # `next_cursor` is the row id to continue from for keyset reads.
    Page = Data.define(:entries, :has_more, :next_cursor) do
      def initialize(entries:, has_more:, next_cursor: nil)
        super
      end
    end

    class << self
      def me(credential:)
        row = Array.wrap(data(HardcoverClient.execute(Queries::ME, {}, credential: credential), "me")).first
        raise HardcoverClient::Error, "Hardcover did not return the connected account" unless row.is_a?(Hash) && positive_id(row["id"])

        Account.new(id: positive_id(row["id"]), username: row["username"].to_s.presence)
      end

      def user_lists(user_id:, credential:)
        rows = data(HardcoverClient.execute(Queries::USER_LISTS, { userId: Integer(user_id), limit: PAGE_SIZE }, credential: credential), "lists")
        Array(rows).filter_map { |row| parse_list(row) }
      end

      # Public lists only, unless `public_only: false` is passed by a caller
      # reading with the list owner's own connection.
      def list(id, credential:, public_only: true)
        query = public_only ? Queries::PUBLIC_LIST : Queries::LIST
        rows = data(HardcoverClient.execute(query, { id: Integer(id) }, credential: credential), "lists")
        list = parse_list(Array(rows).first)
        raise HardcoverClient::NotFoundError, "List not found or not visible to this account" unless list
        raise HardcoverClient::NotFoundError, "List not found or not visible to this account" if public_only && list.public != true

        list
      end

      # Without `since`, pages by offset (previews and browsing). With
      # `since`, reads entries changed since then by descending row id,
      # continuing below `before_id`.
      def list_books(list_id, credential:, offset: 0, since: nil, before_id: nil, limit: PAGE_SIZE, background: false, public_only: true)
        if since
          query = public_only ? Queries::PUBLIC_LIST_BOOKS_SINCE : Queries::LIST_BOOKS_SINCE
          variables = { listId: Integer(list_id), since: since.utc.iso8601, beforeId: before_id || Queries::MAX_ROW_ID, limit: limit }
        else
          query = public_only ? Queries::PUBLIC_LIST_BOOKS : Queries::LIST_BOOKS
          variables = { listId: Integer(list_id), limit: limit, offset: offset }
        end
        rows = Array(data(HardcoverClient.execute(query, variables, credential: credential, background: background), "list_books"))
        entries = rows.filter_map do |row|
          parse_book(row["book"], added_at: parse_time(row["date_added"]), position: row["position"])
        end
        Page.new(entries: entries, has_more: rows.size >= limit, next_cursor: row_ids(rows).min)
      end

      def want_to_read(user_id, credential:, offset: 0, since: nil, before_id: nil, limit: PAGE_SIZE, background: false)
        if since
          query = Queries::WANT_TO_READ_SINCE
          variables = { userId: Integer(user_id), since: since.utc.iso8601, beforeId: before_id || Queries::MAX_ROW_ID, limit: limit }
        else
          query = Queries::WANT_TO_READ
          variables = { userId: Integer(user_id), limit: limit, offset: offset }
        end
        rows = Array(data(HardcoverClient.execute(query, variables, credential: credential, background: background), "user_books"))
        entries = rows.filter_map do |row|
          # updated_at also changes for notes, ratings and privacy edits. It
          # cannot prove when an old record joined Want to Read, so only a
          # newly created record is eligible for automatic requests.
          parse_book(row["book"], added_at: parse_time(row["created_at"]))
        end
        Page.new(entries: entries, has_more: rows.size >= limit, next_cursor: row_ids(rows).min)
      end

      def author(id, credential:)
        rows = data(HardcoverClient.execute(Queries::AUTHOR, { id: Integer(id) }, credential: credential), "authors")
        parse_author(Array(rows).first) || raise(HardcoverClient::NotFoundError, "Author not found")
      end

      # Returns each contribution's book with the author's role on it, newest
      # and upcoming releases first. Role filtering and de-duplication happen
      # in AuthorCatalog.
      def author_contributions(author_id, credential:, offset: 0, limit: PAGE_SIZE, background: false)
        variables = { authorId: Integer(author_id), limit: limit, offset: offset }
        contributions_page(Queries::AUTHOR_RECENT_CONTRIBUTIONS, variables, credential: credential, background: background, limit: limit)
      end

      # The author's contributions in stable id order after `after_id`, used
      # to work through catalogs longer than one recent scan.
      def author_catalog_contributions(author_id, credential:, after_id: 0, limit: PAGE_SIZE, background: false)
        variables = { authorId: Integer(author_id), afterId: Integer(after_id), limit: limit }
        contributions_page(Queries::AUTHOR_CATALOG_CONTRIBUTIONS, variables, credential: credential, background: background, limit: limit)
      end

      def trending_ids(duration:, credential:, offset: 0, limit: 24)
        duration = TRENDING_DURATIONS.include?(duration.to_s) ? duration.to_s : "month"
        payload = data(HardcoverClient.execute(Queries::TRENDING, { duration: duration, limit: limit, offset: offset }, credential: credential), "books_trending")
        raise HardcoverClient::Error, "Hardcover trending error: #{payload['error'].to_s.truncate(200)}" if payload.is_a?(Hash) && payload["error"].present?

        Array(payload.is_a?(Hash) ? payload["ids"] : nil).filter_map { |value| positive_id(value) }
      end

      # Preserves the requested order, which matters for trending results.
      def books_by_ids(ids, credential:)
        ids = Array(ids).filter_map { |value| positive_id(value) }.uniq
        return [] if ids.empty?

        rows = Array(data(HardcoverClient.execute(Queries::BOOKS_BY_IDS, { ids: ids }, credential: credential), "books"))
        by_id = rows.filter_map { |row| parse_book(row) }.index_by(&:id)
        ids.filter_map { |id| by_id[id] }
      end

      def releases(from:, to:, credential:, offset: 0, limit: 24)
        variables = { from: from.to_date.iso8601, to: to.to_date.iso8601, limit: limit, offset: offset }
        rows = Array(data(HardcoverClient.execute(Queries::RELEASES, variables, credential: credential), "books"))
        Page.new(entries: rows.filter_map { |row| parse_book(row) }, has_more: rows.size >= limit)
      end

      def popular_lists(credential:, offset: 0, limit: 24)
        rows = Array(data(HardcoverClient.execute(Queries::POPULAR_LISTS, { limit: limit, offset: offset }, credential: credential), "lists"))
        Page.new(entries: rows.filter_map { |row| parse_list(row) }, has_more: rows.size >= limit)
      end

      def search_lists(query, credential:, page: 1, per_page: 24)
        hits = search_hits(query, "List", credential: credential, page: page, per_page: per_page)
        Page.new(entries: hits.filter_map { |doc| parse_list_document(doc) }, has_more: hits.size >= per_page)
      end

      def search_authors(query, credential:, page: 1, per_page: 24)
        hits = search_hits(query, "Author", credential: credential, page: page, per_page: per_page)
        Page.new(entries: hits.filter_map { |doc| parse_author_document(doc) }, has_more: hits.size >= per_page)
      end

      def genre_books(genre, credential:, page: 1, per_page: 24)
        variables = { query: genre.to_s, perPage: per_page, page: page }
        payload = data(HardcoverClient.execute(Queries::GENRE_SEARCH, variables, credential: credential), "search")
        hits = extract_documents(payload)
        Page.new(entries: hits.filter_map { |doc| parse_book_document(doc) }, has_more: hits.size >= per_page)
      end

      def parse_book(row, added_at: nil, position: nil, role: nil, languages: [])
        return unless row.is_a?(Hash)

        id = positive_id(row["id"])
        title = row["title"].to_s.squish
        return if id.nil? || title.blank?

        authors = primary_authors(row["contributions"])
        series = row["featured_book_series"]
        series = series.first if series.is_a?(Array)
        series = {} unless series.is_a?(Hash)

        BookEntry.new(
          id: id,
          title: title,
          author: authors.map { |author| author[:name] }.uniq.first(3).join(", ").presence,
          author_ids: authors.filter_map { |author| author[:id] }.uniq,
          description: row["description"].to_s.strip.truncate(2_000).presence,
          release_date: parse_date(row["release_date"]),
          release_year: Integer(row["release_year"], exception: false),
          cover_url: extract_cover_url(row["cached_image"]),
          series_id: positive_id(series.dig("series", "id")),
          series_name: series.dig("series", "name").to_s.presence,
          series_position: normalize_position(series["position"]),
          users_count: Integer(row["users_count"], exception: false),
          rating: Float(row["rating"], exception: false)&.round(2),
          has_audiobook: positive_id(row["default_audio_edition_id"]).present?,
          has_ebook: positive_id(row["default_ebook_edition_id"]).present?,
          compilation: row["compilation"] == true,
          canonical_id: positive_id(row["canonical_id"]),
          created_at: parse_time(row["created_at"]),
          added_at: added_at,
          position: Integer(position, exception: false),
          role: role.to_s.strip.presence,
          languages: Array(languages)
        )
      end

      def primary_role?(role)
        PRIMARY_ROLES.include?(role.to_s.strip.downcase)
      end

      private

      def data(response, key)
        response.is_a?(Hash) ? response.dig("data", key) : nil
      end

      def row_ids(rows)
        rows.filter_map { |row| positive_id(row["id"]) if row.is_a?(Hash) }
      end

      def contributions_page(query, variables, credential:, background:, limit:)
        rows = Array(data(HardcoverClient.execute(query, variables, credential: credential, background: background), "contributions"))
        entries = rows.filter_map do |row|
          book = row["book"]
          next unless book.is_a?(Hash)

          languages = %w[default_ebook_edition default_audio_edition default_physical_edition].filter_map do |key|
            book.dig(key, "language", "code2").to_s.downcase.presence
          end.uniq
          parse_book(book, role: row["contribution"], languages: languages)
        end
        Page.new(entries: entries, has_more: rows.size >= limit, next_cursor: row_ids(rows).max)
      end

      def search_hits(query, type, credential:, page:, per_page:)
        variables = { query: query.to_s.strip.first(200), queryType: type, perPage: per_page, page: page }
        extract_documents(data(HardcoverClient.execute(Queries::SEARCH, variables, credential: credential), "search"))
      end

      def extract_documents(payload)
        results = payload.is_a?(Hash) ? payload["results"] : nil
        hits = results.is_a?(Hash) ? results["hits"] : nil
        Array(hits).filter_map { |hit| hit["document"] if hit.is_a?(Hash) && hit["document"].is_a?(Hash) }
      end

      def primary_authors(contributions)
        Array(contributions).filter_map do |contribution|
          next unless contribution.is_a?(Hash) && primary_role?(contribution["contribution"])

          author = contribution["author"]
          next unless author.is_a?(Hash) && author["name"].present?

          { id: positive_id(author["id"]), name: author["name"].to_s.squish }
        end
      end

      def parse_list(row)
        return unless row.is_a?(Hash) && positive_id(row["id"]) && row["name"].present?

        ListSummary.new(
          id: positive_id(row["id"]),
          name: row["name"].to_s.squish,
          slug: row["slug"].to_s.presence,
          description: row["description"].to_s.strip.truncate(1_000).presence,
          books_count: Integer(row["books_count"], exception: false) || 0,
          likes_count: Integer(row["likes_count"], exception: false),
          owner_username: row.dig("user", "username").to_s.presence,
          owner_id: positive_id(row["user_id"]),
          public: list_public(row)
        )
      end

      # Public means privacy_setting_id 1 (1 public, 2 followers, 3 private);
      # a `public: false` flag is honoured too. Unknown stays nil.
      def list_public(row)
        return nil unless row.key?("privacy_setting_id")

        row["privacy_setting_id"].to_i == 1 && row["public"] != false
      end

      def parse_list_document(doc)
        parse_list(doc.merge("user" => doc["user"].is_a?(Hash) ? doc["user"] : {}))
      end

      def parse_author(row)
        return unless row.is_a?(Hash) && positive_id(row["id"]) && row["name"].present?

        AuthorSummary.new(
          id: positive_id(row["id"]),
          name: row["name"].to_s.squish,
          slug: row["slug"].to_s.presence,
          bio: row["bio"].to_s.strip.truncate(1_500).presence,
          books_count: Integer(row["books_count"], exception: false),
          image_url: extract_cover_url(row["cached_image"] || row["image"]),
          canonical_id: positive_id(row["canonical_id"]),
          top_titles: Array(row["books"]).map(&:to_s).compact_blank.first(5)
        )
      end

      def parse_author_document(doc)
        parse_author(doc)
      end

      def parse_book_document(doc)
        return unless doc.is_a?(Hash)

        id = positive_id(doc["id"])
        title = doc["title"].to_s.squish
        return if id.nil? || title.blank?

        series = doc["featured_series"].is_a?(Hash) ? doc["featured_series"] : {}
        BookEntry.new(
          id: id,
          title: title,
          author: Array(doc["author_names"]).first(3).join(", ").presence,
          author_ids: [],
          description: doc["description"].to_s.strip.truncate(2_000).presence,
          release_date: nil,
          release_year: Integer(doc["release_year"], exception: false),
          cover_url: extract_cover_url(doc["image"]),
          series_id: positive_id(series.dig("series", "id") || series["series_id"]),
          series_name: (series.dig("series", "name") || Array(doc["series_names"]).first).to_s.presence,
          series_position: normalize_position(doc["featured_series_position"]),
          users_count: Integer(doc["users_count"], exception: false),
          rating: Float(doc["rating"], exception: false)&.round(2),
          has_audiobook: doc["has_audiobook"] == true,
          has_ebook: doc["has_ebook"] == true,
          compilation: doc["compilation"] == true,
          canonical_id: nil,
          created_at: nil,
          added_at: nil,
          position: nil,
          role: nil,
          languages: []
        )
      end

      def extract_cover_url(value)
        url = value.is_a?(Hash) ? value["url"] : value
        url = url.to_s.strip
        url if url.start_with?("https://")
      end

      def normalize_position(value)
        return if value.blank?

        number = Float(value, exception: false)
        return value.to_s.strip.first(20) unless number

        number == number.to_i ? number.to_i.to_s : number.to_s
      end

      def positive_id(value)
        id = Integer(value, exception: false)
        id if id&.positive?
      end

      def parse_date(value)
        Date.iso8601(value.to_s.first(10)) if value.present?
      rescue ArgumentError
        nil
      end

      def parse_time(value)
        Time.zone.parse(value.to_s) if value.present?
      rescue ArgumentError
        nil
      end
    end
  end
end
