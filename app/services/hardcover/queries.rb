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

    LIST = <<~GRAPHQL.freeze
      query ShelfarrList($id: Int!) {
        lists(where: { id: { _eq: $id } }, limit: 1) {
          id
          name
          slug
          description
          books_count
          likes_count
          privacy_setting_id
          user {
            username
          }
        }
      }
    GRAPHQL

    LIST_BOOKS = <<~GRAPHQL.freeze
      query ShelfarrListBooks($listId: Int!, $limit: Int!, $offset: Int!) {
        list_books(where: { list_id: { _eq: $listId } }, order_by: [{ id: desc }], limit: $limit, offset: $offset) {
          id
          position
          date_added
          updated_at
          book {
            #{BOOK_FIELDS}
          }
        }
      }
    GRAPHQL

    LIST_BOOKS_SINCE = <<~GRAPHQL.freeze
      query ShelfarrListBooksSince($listId: Int!, $since: timestamptz!, $limit: Int!, $offset: Int!) {
        list_books(
          where: { list_id: { _eq: $listId }, _or: [{ date_added: { _gte: $since } }, { updated_at: { _gte: $since } }] }
          order_by: [{ id: desc }]
          limit: $limit
          offset: $offset
        ) {
          id
          position
          date_added
          updated_at
          book {
            #{BOOK_FIELDS}
          }
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

    WANT_TO_READ_SINCE = <<~GRAPHQL.freeze
      query ShelfarrWantToReadSince($userId: Int!, $since: timestamptz!, $limit: Int!, $offset: Int!) {
        user_books(
          where: {
            user_id: { _eq: $userId }
            status_id: { _eq: 1 }
            _or: [{ created_at: { _gte: $since } }, { updated_at: { _gte: $since } }]
          }
          order_by: [{ id: desc }]
          limit: $limit
          offset: $offset
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

    AUTHOR_CONTRIBUTIONS = <<~GRAPHQL.freeze
      query ShelfarrAuthorContributions($authorId: Int!, $limit: Int!, $offset: Int!) {
        contributions(
          where: { author_id: { _eq: $authorId }, contributable_type: { _eq: "Book" } }
          order_by: [{ id: asc }]
          limit: $limit
          offset: $offset
        ) {
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
          where: { public: { _eq: true }, books_count: { _gt: 0 } }
          order_by: [{ likes_count: desc }, { id: asc }]
          limit: $limit
          offset: $offset
        ) {
          id
          name
          slug
          description
          books_count
          likes_count
          user {
            username
          }
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
