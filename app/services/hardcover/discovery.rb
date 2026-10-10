# frozen_string_literal: true

module Hardcover
  # Public catalog browsing backed by Hardcover. Results are cached and
  # shared by every Shelfarr user, so browsing does not multiply API calls.
  # Only data Hardcover exposes is offered: trending, release windows, genre
  # search, public lists, and author catalogs. There are no personalized
  # recommendations.
  module Discovery
    CACHE_VERSION = 1
    PER_PAGE = 24
    MAX_PAGE = 20
    AUTHOR_PAGES = 3
    BOOK_VIEWS = %w[trending new upcoming genre].freeze
    TRENDING_PERIODS = {
      "week" => "This week",
      "month" => "This month",
      "three_month" => "Last 3 months",
      "one_year" => "This year"
    }.freeze
    GENRES = [
      "Fantasy", "Science Fiction", "Romance", "Mystery", "Thriller", "Horror", "Historical Fiction",
      "Literary Fiction", "Young Adult", "Nonfiction", "Biography", "History", "Self Help", "Classics"
    ].freeze
    TTL = {
      trending: 6.hours,
      releases: 6.hours,
      genre: 12.hours,
      lists: 1.hour,
      list: 30.minutes,
      authors: 6.hours,
      author: 6.hours
    }.freeze

    AuthorView = Data.define(:author, :books, :excluded, :truncated)
    ListView = Data.define(:list, :books, :has_more)

    class << self
      def books(view:, credential:, page: 1, period: "month", genre: nil, today: Date.current)
        page = page.to_i.clamp(1, MAX_PAGE)
        offset = (page - 1) * PER_PAGE

        case view
        when "new"
          cached(:releases, "new", today.iso8601, page) do
            API.releases(from: today - 90, to: today, credential: credential, offset: offset, limit: PER_PAGE)
          end
        when "upcoming"
          cached(:releases, "upcoming", today.iso8601, page) do
            API.releases(from: today + 1, to: today + 180, credential: credential, offset: offset, limit: PER_PAGE)
          end
        when "genre"
          genre = genre.to_s.squish.first(60)
          return API::Page.new(entries: [], has_more: false) if genre.blank?

          cached(:genre, genre.downcase, page) { API.genre_books(genre, credential: credential, page: page, per_page: PER_PAGE) }
        else
          period = TRENDING_PERIODS.key?(period) ? period : "month"
          cached(:trending, period, page) do
            ids = API.trending_ids(duration: period, credential: credential, offset: offset, limit: PER_PAGE)
            API::Page.new(entries: API.books_by_ids(ids, credential: credential), has_more: ids.size >= PER_PAGE)
          end
        end
      end

      def lists(credential:, query: nil, page: 1)
        page = page.to_i.clamp(1, MAX_PAGE)
        query = query.to_s.squish.first(100)
        if query.present?
          cached(:lists, "search", query.downcase, page) { API.search_lists(query, credential: credential, page: page, per_page: PER_PAGE) }
        else
          cached(:lists, "popular", page) { API.popular_lists(credential: credential, offset: (page - 1) * PER_PAGE, limit: PER_PAGE) }
        end
      end

      def list(id, credential:, page: 1)
        page = page.to_i.clamp(1, MAX_PAGE)
        cached(:list, id.to_i, page) do
          list = API.list(id, credential: credential)
          books = API.list_books(list.id, credential: credential, offset: (page - 1) * PER_PAGE, limit: PER_PAGE)
          ListView.new(list: list, books: books.entries, has_more: books.has_more)
        end
      end

      def authors(query, credential:, page: 1)
        query = query.to_s.squish.first(100)
        return API::Page.new(entries: [], has_more: false) if query.blank?

        page = page.to_i.clamp(1, MAX_PAGE)
        cached(:authors, query.downcase, page) { API.search_authors(query, credential: credential, page: page, per_page: PER_PAGE) }
      end

      # Reads up to AUTHOR_PAGES pages of contributions and applies the same
      # role, duplicate, and language filtering used by author monitoring.
      def author(id, credential:)
        cached(:author, id.to_i, AuthorCatalog.enabled_languages.join(",")) do
          author = API.author(id, credential: credential)
          raw = []
          truncated = false
          AUTHOR_PAGES.times do |index|
            page = API.author_contributions(author.id, credential: credential, offset: index * API::PAGE_SIZE)
            raw.concat(page.entries)
            break unless page.has_more

            truncated = index == AUTHOR_PAGES - 1
          end
          catalog = AuthorCatalog.filter(raw)
          AuthorView.new(author: author, books: catalog.entries, excluded: catalog.excluded, truncated: truncated)
        end
      end

      private

      # Only successful responses are cached; errors propagate to the caller.
      def cached(kind, *parts, &block)
        key = [ "hardcover", "discovery", "v#{CACHE_VERSION}", kind, *parts ].join(":")
        Rails.cache.fetch(key, expires_in: TTL.fetch(kind), &block)
      rescue TypeError, ArgumentError => e
        # Unserializable values (should not happen) fall back to a live read.
        Rails.logger.warn("[Hardcover::Discovery] Cache bypassed: #{e.class}")
        yield
      end
    end
  end
end
