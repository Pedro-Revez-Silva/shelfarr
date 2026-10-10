# frozen_string_literal: true

require "test_helper"

class Hardcover::APITest < ActiveSupport::TestCase
  setup do
    @credential = HardcoverClient.credential_for_token("hc_at_api", budget_key: HardcoverClient.account_budget_key(4242))
  end

  test "me accepts Hardcover's array response" do
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 4242, "username" => "reader" } ] })

    account = Hardcover::API.me(credential: @credential)

    assert_equal 4242, account.id
    assert_equal "reader", account.username
  end

  test "me refuses a response without an account id" do
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [] })

    assert_raises(HardcoverClient::Error) { Hardcover::API.me(credential: @credential) }
  end

  test "want_to_read reads status 1 for the account and marks a full page as having more" do
    rows = 100.times.map { |index| hardcover_user_book_row(hardcover_book(id: 1_000 + index), id: 50_000 + index) }
    stub_hardcover_graphql("ShelfarrWantToRead" => { "user_books" => rows })

    page = Hardcover::API.want_to_read(4242, credential: @credential)

    assert_equal 100, page.entries.size
    assert page.has_more
    assert_equal({ "userId" => 4242, "limit" => 100, "offset" => 0 }, hardcover_requests.last[:variables])
  end

  test "incremental want_to_read sends the since cursor and records when the entry changed" do
    since = Time.zone.parse("2026-09-01T00:00:00Z")
    row = hardcover_user_book_row(hardcover_book(id: 12), id: 99, created_at: "2025-01-01T00:00:00+00:00", updated_at: "2026-09-02T08:00:00+00:00")
    stub_hardcover_graphql("ShelfarrWantToReadSince" => { "user_books" => [ row ] })

    page = Hardcover::API.want_to_read(4242, credential: @credential, since: since)

    assert_equal "2026-09-01T00:00:00Z", hardcover_requests.last[:variables]["since"]
    assert_equal 2_147_483_647, hardcover_requests.last[:variables]["beforeId"], "the first page starts at the newest row"
    assert_equal Time.zone.parse("2026-09-02T08:00:00Z"), page.entries.first.added_at
    assert_not page.has_more
    assert_equal 99, page.next_cursor
  end

  test "incremental reads continue below the last row id instead of using an offset" do
    rows = [ hardcover_list_book_row(hardcover_book(id: 1), id: 80), hardcover_list_book_row(hardcover_book(id: 2), id: 75) ]
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => rows })

    page = Hardcover::API.list_books(55, credential: @credential, since: 1.day.ago, before_id: 90, limit: 2)

    variables = hardcover_requests.last[:variables]
    assert_equal [ 90, 2 ], variables.values_at("beforeId", "limit")
    assert_not variables.key?("offset")
    assert page.has_more
    assert_equal 75, page.next_cursor
  end

  test "lists are public-only unless the owner's connection asks otherwise" do
    public_row = { "id" => 3, "name" => "Open", "privacy_setting_id" => 1, "public" => true, "user_id" => 9, "user" => { "username" => "curator" } }
    stub_hardcover_graphql(
      "ShelfarrPublicList" => { "lists" => [ public_row ] },
      "ShelfarrList" => { "lists" => [ public_row.merge("privacy_setting_id" => 3, "public" => false) ] }
    )

    list = Hardcover::API.list(3, credential: @credential)
    assert_equal [ true, 9 ], [ list.public, list.owner_id ]
    assert_equal "ShelfarrPublicList", hardcover_requests.last[:operation]
    assert_includes Hardcover::Queries::PUBLIC_LIST, "privacy_setting_id: { _eq: 1 }"

    owned = Hardcover::API.list(3, credential: @credential, public_only: false)
    assert_equal false, owned.public
  end

  test "a list that is not public is never returned by a public read" do
    stub_hardcover_graphql("ShelfarrPublicList" => { "lists" => [ { "id" => 3, "name" => "Secret", "privacy_setting_id" => 2, "user_id" => 9 } ] })

    assert_raises(HardcoverClient::NotFoundError) { Hardcover::API.list(3, credential: @credential) }
  end

  test "parses list books into requestable entries" do
    book = hardcover_book(id: 321, title: "The Left Hand of Darkness", author: "Ursula K. Le Guin", series: "Hainish Cycle", position: 4.0, audio: false)
    stub_hardcover_graphql("ShelfarrPublicListBooks" => { "list_books" => [ hardcover_list_book_row(book, id: 1, position: 2) ] })

    entry = Hardcover::API.list_books(55, credential: @credential).entries.first

    assert_equal "hardcover:321", entry.work_id
    assert_equal "Ursula K. Le Guin", entry.author
    assert_equal "Hainish Cycle", entry.series_name
    assert_equal "4", entry.series_position
    assert_equal 2, entry.position
    assert_equal Date.new(2021, 4, 6), entry.release_date
    assert entry.has_ebook
    assert_not entry.has_audiobook
    assert_equal "https://assets.hardcover.app/books/321/cover.jpg", entry.cover_url
    assert_equal [ { source_name: "Hardcover", source_url: "https://hardcover.app/id/book/321", work_id: "hardcover:321" } ], entry.sources
  end

  test "book author excludes non-author contributors" do
    book = hardcover_book(id: 5, author: "Original Author", extra_contributors: [
      { "contribution" => "Translator", "author" => { "id" => 2, "name" => "Some Translator" } },
      { "contribution" => "Narrator", "author" => { "id" => 3, "name" => "Some Narrator" } }
    ])

    entry = Hardcover::API.parse_book(book)

    assert_equal "Original Author", entry.author
    assert_equal [ 501 ], entry.author_ids
  end

  test "skips rows without a usable id or title" do
    stub_hardcover_graphql("ShelfarrPublicListBooks" => { "list_books" => [
      hardcover_list_book_row({ "id" => nil, "title" => "x" }, id: 1),
      hardcover_list_book_row(hardcover_book(id: 6, title: " "), id: 2),
      hardcover_list_book_row(hardcover_book(id: 7), id: 3)
    ] })

    assert_equal [ 7 ], Hardcover::API.list_books(55, credential: @credential).entries.map(&:id)
  end

  test "trending keeps Hardcover's ranking when loading book details" do
    stub_hardcover_graphql(
      "ShelfarrTrending" => { "books_trending" => { "ids" => [ 30, 10, 20 ], "error" => nil } },
      "ShelfarrBooksByIds" => { "books" => [ hardcover_book(id: 10), hardcover_book(id: 20), hardcover_book(id: 30) ] }
    )

    ids = Hardcover::API.trending_ids(duration: "week", credential: @credential)
    books = Hardcover::API.books_by_ids(ids, credential: @credential)

    assert_equal [ 30, 10, 20 ], books.map(&:id)
    assert_equal "week", hardcover_requests.first[:variables]["duration"]
  end

  test "trending rejects unsupported durations and surfaces provider errors" do
    stub_hardcover_graphql("ShelfarrTrending" => { "books_trending" => { "ids" => nil, "error" => "Something failed" } })

    assert_raises(HardcoverClient::Error) { Hardcover::API.trending_ids(duration: "decade", credential: @credential) }
    assert_equal "month", hardcover_requests.last[:variables]["duration"]
  end

  test "list search parses Typesense documents" do
    stub_hardcover_graphql("ShelfarrSearch" => { "search" => { "ids" => [ 3 ], "results" => { "hits" => [
      { "document" => { "id" => "3", "name" => "NPR Top 100 SF/F", "slug" => "npr-top-100", "books_count" => 100, "likes_count" => 50,
        "description" => "Classics", "user" => { "username" => "hardcover" } } }
    ] } } })

    list = Hardcover::API.search_lists("npr", credential: @credential).entries.first

    assert_equal 3, list.id
    assert_equal "https://hardcover.app/@hardcover/lists/npr-top-100", list.hardcover_url
    assert_equal "List", hardcover_requests.last[:variables]["queryType"]
  end

  test "author contributions carry the contribution role and edition languages" do
    stub_hardcover_graphql("ShelfarrAuthorRecentContributions" => { "contributions" => [
      hardcover_contribution_row(hardcover_book(id: 1), id: 1, contribution: nil, languages: [ "en" ]),
      hardcover_contribution_row(hardcover_book(id: 2), id: 2, contribution: "Editor", languages: [ "fr", "fr" ])
    ] })

    entries = Hardcover::API.author_contributions(501, credential: @credential).entries

    assert_equal [ nil, "Editor" ], entries.map(&:role)
    assert_equal [ [ "en" ], [ "fr" ] ], entries.map(&:languages)
    assert_includes Hardcover::Queries::AUTHOR_RECENT_CONTRIBUTIONS, "release_date: desc_nulls_last"
  end

  test "the author catalog walk continues after the highest contribution id" do
    stub_hardcover_graphql("ShelfarrAuthorCatalogContributions" => { "contributions" => [
      hardcover_contribution_row(hardcover_book(id: 1), id: 201), hardcover_contribution_row(hardcover_book(id: 2), id: 202)
    ] })

    page = Hardcover::API.author_catalog_contributions(501, credential: @credential, after_id: 200, limit: 2)

    assert_equal 200, hardcover_requests.last[:variables]["afterId"]
    assert page.has_more
    assert_equal 202, page.next_cursor
  end
end
