# frozen_string_literal: true

module Hardcover
  # GraphQL documents for the discovery, reading-list, and author features.
  # Each document has exactly one top-level field because Hardcover charges
  # one rate-limit token per top-level field and rejects requests with more
  # fields than the account's burst size.
  module Queries
    BOOK_FIELDS = <<~GRAPHQL.freeze
      id
      title
      description
      release_date
      release_year
      users_count
      rating
      compilation
      canonical_id
      created_at
      cached_image
      default_audio_edition_id
      default_ebook_edition_id
      contributions(where: { contributable_type: { _eq: "Book" } }, limit: 6) {
        contribution
        author {
          id
          name
        }
      }
      featured_book_series {
        position
        series {
          id
          name
        }
      }
    GRAPHQL

    ME = <<~GRAPHQL.freeze
      query ShelfarrMe {
        me {
          id
          username
        }
      }
    GRAPHQL

    USER_LISTS = <<~GRAPHQL.freeze
      query ShelfarrUserLists($userId: Int!, $limit: Int!) {
        lists(where: { user_id: { _eq: $userId } }, order_by: [{ updated_at: desc_nulls_last }, { id: desc }], limit: $limit) {
          id
          name
          slug
          description
          books_count
          privacy_setting_id
        }
      }
    GRAPHQL

    # Hardcover lists are public (privacy_setting_id 1), followers-only (2),
    # or private (3). Discovery and anything read with a credential other
    # than the list owner's own connection is restricted to public lists in
    # the query itself, so private entries never reach Shelfarr.
    PUBLIC_LIST_FILTER = "privacy_setting_id: { _eq: 1 }, public: { _eq: true }"
    LIST_FIELDS = <<~GRAPHQL.freeze
      id
      name
      slug
      description
      books_count
      likes_count
      privacy_setting_id
      public
      user_id
      user {
        username
      }
    GRAPHQL
    # Keyset start for incremental reads ordered by descending row id.
    MAX_ROW_ID = 2_147_483_647

    LIST = <<~GRAPHQL.freeze
      query ShelfarrList($id: Int!) {
        lists(where: { id: { _eq: $id } }, limit: 1) {
          #{LIST_FIELDS}
        }
      }
    GRAPHQL

    PUBLIC_LIST = <<~GRAPHQL.freeze
      query ShelfarrPublicList($id: Int!) {
        lists(where: { id: { _eq: $id }, #{PUBLIC_LIST_FILTER} }, limit: 1) {
          #{LIST_FIELDS}
        }
      }
    GRAPHQL

    LIST_BOOK_FIELDS = <<~GRAPHQL.freeze
      id
      position
      date_added
      updated_at
      book {
        #{BOOK_FIELDS}
      }
    GRAPHQL

    LIST_BOOKS = <<~GRAPHQL.freeze
      query ShelfarrListBooks($listId: Int!, $limit: Int!, $offset: Int!) {
        list_books(where: { list_id: { _eq: $listId } }, order_by: [{ id: desc }], limit: $limit, offset: $offset) {
          #{LIST_BOOK_FIELDS}
        }
      }
    GRAPHQL

    PUBLIC_LIST_BOOKS = <<~GRAPHQL.freeze
      query ShelfarrPublicListBooks($listId: Int!, $limit: Int!, $offset: Int!) {
        list_books(
          where: { list_id: { _eq: $listId }, list: { #{PUBLIC_LIST_FILTER} } }
          order_by: [{ id: desc }]
          limit: $limit
          offset: $offset
        ) {
          #{LIST_BOOK_FIELDS}
        }
      }
    GRAPHQL

    # Incremental reads page by row id (keyset) so a window can be resumed
    # after a restart without skipping or re-reading rows.
    LIST_BOOKS_SINCE = <<~GRAPHQL.freeze
      query ShelfarrListBooksSince($listId: Int!, $since: timestamptz!, $beforeId: Int!, $limit: Int!) {
        list_books(
          where: {
            list_id: { _eq: $listId }
            id: { _lt: $beforeId }
            _or: [{ date_added: { _gte: $since } }, { updated_at: { _gte: $since } }]
          }
          order_by: [{ id: desc }]
          limit: $limit
        ) {
          #{LIST_BOOK_FIELDS}
        }
      }
    GRAPHQL

    PUBLIC_LIST_BOOKS_SINCE = <<~GRAPHQL.freeze
      query ShelfarrPublicListBooksSince($listId: Int!, $since: timestamptz!, $beforeId: Int!, $limit: Int!) {
        list_books(
          where: {
            list_id: { _eq: $listId }
            list: { #{PUBLIC_LIST_FILTER} }
            id: { _lt: $beforeId }
            _or: [{ date_added: { _gte: $since } }, { updated_at: { _gte: $since } }]
          }
          order_by: [{ id: desc }]
          limit: $limit
        ) {
          #{LIST_BOOK_FIELDS}
        }
      }
    GRAPHQL

    WANT_TO_READ = <<~GRAPHQL.freeze
      query ShelfarrWantToRead($userId: Int!, $limit: Int!, $offset: Int!) {
        user_books(where: { user_id: { _eq: $userId }, status_id: { _eq: 1 } }, order_by: [{ id: desc }], limit: $limit, offset: $offset) {
          id
          created_at
          updated_at
          book {
            #{BOOK_FIELDS}
          }
        }
      }
    GRAPHQL

    # A shelf change (for example Read -> Want to Read) updates the
    # user_books row, so updated_at covers moves as well as new additions.
    WANT_TO_READ_SINCE = <<~GRAPHQL.freeze
      query ShelfarrWantToReadSince($userId: Int!, $since: timestamptz!, $beforeId: Int!, $limit: Int!) {
        user_books(
          where: {
            user_id: { _eq: $userId }
            status_id: { _eq: 1 }
            id: { _lt: $beforeId }
            _or: [{ created_at: { _gte: $since } }, { updated_at: { _gte: $since } }]
          }
          order_by: [{ id: desc }]
          limit: $limit
        ) {
          id
          created_at
          updated_at
          book {
            #{BOOK_FIELDS}
          }
        }
      }
    GRAPHQL

    AUTHOR = <<~GRAPHQL.freeze
      query ShelfarrAuthor($id: Int!) {
        authors(where: { id: { _eq: $id } }, limit: 1) {
          id
          name
          slug
          bio
          books_count
          canonical_id
          cached_image
        }
      }
    GRAPHQL

    CONTRIBUTION_FIELDS = <<~GRAPHQL.freeze
      id
      contribution
      book {
        #{BOOK_FIELDS}
        default_ebook_edition {
          language {
            code2
          }
        }
        default_audio_edition {
          language {
            code2
          }
        }
        default_physical_edition {
          language {
            code2
          }
        }
      }
    GRAPHQL

    # Newest and upcoming releases first, so new books are always inside the
    # bounded scan no matter how long the author's catalog is.
    AUTHOR_RECENT_CONTRIBUTIONS = <<~GRAPHQL.freeze
      query ShelfarrAuthorRecentContributions($authorId: Int!, $limit: Int!, $offset: Int!) {
        contributions(
          where: { author_id: { _eq: $authorId }, contributable_type: { _eq: "Book" } }
          order_by: [{ book: { release_date: desc_nulls_last } }, { id: desc }]
          limit: $limit
          offset: $offset
        ) {
          #{CONTRIBUTION_FIELDS}
        }
      }
    GRAPHQL

    # Walks a long catalog in stable id order across checks, so books older
    # than the recent scan are still listed and kept up to date.
    AUTHOR_CATALOG_CONTRIBUTIONS = <<~GRAPHQL.freeze
      query ShelfarrAuthorCatalogContributions($authorId: Int!, $afterId: bigint!, $limit: Int!) {
        contributions(
          where: { author_id: { _eq: $authorId }, contributable_type: { _eq: "Book" }, id: { _gt: $afterId } }
          order_by: [{ id: asc }]
          limit: $limit
        ) {
          #{CONTRIBUTION_FIELDS}
        }
      }
    GRAPHQL

    TRENDING = <<~GRAPHQL.freeze
      query ShelfarrTrending($duration: TrendingDuration!, $limit: Int!, $offset: Int!) {
        books_trending(duration: $duration, limit: $limit, offset: $offset) {
          ids
          error
        }
      }
    GRAPHQL

    BOOKS_BY_IDS = <<~GRAPHQL.freeze
      query ShelfarrBooksByIds($ids: [Int!]!) {
        books(where: { id: { _in: $ids } }) {
          #{BOOK_FIELDS}
        }
      }
    GRAPHQL

    RELEASES = <<~GRAPHQL.freeze
      query ShelfarrReleases($from: date!, $to: date!, $limit: Int!, $offset: Int!) {
        books(
          where: {
            release_date: { _gte: $from, _lte: $to }
            canonical_id: { _is_null: true }
            compilation: { _eq: false }
            users_count: { _gt: 0 }
          }
          order_by: [{ users_count: desc }, { id: asc }]
          limit: $limit
          offset: $offset
        ) {
          #{BOOK_FIELDS}
        }
      }
    GRAPHQL

    POPULAR_LISTS = <<~GRAPHQL.freeze
      query ShelfarrPopularLists($limit: Int!, $offset: Int!) {
        lists(
          where: { #{PUBLIC_LIST_FILTER}, books_count: { _gt: 0 } }
          order_by: [{ likes_count: desc }, { id: asc }]
          limit: $limit
          offset: $offset
        ) {
          #{LIST_FIELDS}
        }
      }
    GRAPHQL

    SEARCH = <<~GRAPHQL.freeze
      query ShelfarrSearch($query: String!, $queryType: String!, $perPage: Int!, $page: Int!) {
        search(query: $query, query_type: $queryType, per_page: $perPage, page: $page) {
          ids
          results
        }
      }
    GRAPHQL

    GENRE_SEARCH = <<~GRAPHQL.freeze
      query ShelfarrGenreSearch($query: String!, $perPage: Int!, $page: Int!) {
        search(
          query: $query
          query_type: "Book"
          fields: "genres"
          weights: "1"
          typos: "0"
          sort: "_text_match:desc,users_count:desc"
          per_page: $perPage
          page: $page
        ) {
          ids
          results
        }
      }
    GRAPHQL

    def self.all
      constants(false).filter_map do |name|
        value = const_get(name)
        [ name.to_s, value ] if value.is_a?(String) && value.lstrip.start_with?("query ")
      end.to_h
    end
  end
end
