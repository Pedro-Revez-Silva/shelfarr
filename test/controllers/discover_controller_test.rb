# frozen_string_literal: true

require "test_helper"

class DiscoverControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    configure_hardcover_instance_token
  end

  test "trending books show per-format ownership and request links" do
    owned = Book.create!(title: "Owned Ebook", hardcover_id: "101", book_type: :ebook, file_path: "/ebooks/owned.epub")
    Book.create!(title: "Owned Ebook", hardcover_id: "101", book_type: :audiobook, file_path: "/audio/owned")
    requested_book = Book.create!(title: "Requested", hardcover_id: "102", book_type: :ebook)
    Request.create!(user: users(:two), book: requested_book)
    Book.create!(title: "Requested", hardcover_id: "102", book_type: :audiobook)
    stub_hardcover_graphql(
      "ShelfarrTrending" => { "books_trending" => { "ids" => [ 101, 102, 103 ], "error" => nil } },
      "ShelfarrBooksByIds" => { "books" => [ hardcover_book(id: 101, title: "Owned Ebook"), hardcover_book(id: 102, title: "Requested"), hardcover_book(id: 103, title: "Fresh") ] }
    )

    get discover_path(view: "trending", period: "week")

    assert_response :success
    assert_select "h3", text: "Owned Ebook"
    assert_includes response.body, "In library"
    assert_includes response.body, "Requested"
    assert_select "a[href^='/requests/new']", count: 2, message: "partially requested and new books stay requestable"
    assert_includes response.body, "Book data from Hardcover"
    assert owned.persisted?
  end

  test "release views query Hardcover's release date window" do
    stub_hardcover_graphql("ShelfarrReleases" => { "books" => [ hardcover_book(id: 201, title: "Upcoming One", release_date: 1.month.from_now.to_date.iso8601) ] })

    travel_to Date.new(2026, 10, 10) do
      get discover_path(view: "upcoming")
    end

    assert_response :success
    assert_includes response.body, "Upcoming One"
    assert_equal [ "2026-10-11", "2027-04-08" ], hardcover_requests.last[:variables].values_at("from", "to")
  end

  test "genre view uses Hardcover's genre search field" do
    stub_hardcover_graphql("ShelfarrGenreSearch" => { "search" => { "ids" => [ 5 ], "results" => { "hits" => [
      { "document" => { "id" => "5", "title" => "Cozy Book", "author_names" => [ "Writer" ], "release_year" => 2022, "image" => { "url" => "https://assets.hardcover.app/5.jpg" } } }
    ] } } })

    get discover_path(view: "genre", genre: "Cozy Mystery")

    assert_includes response.body, "Cozy Book"
    assert_equal "Cozy Mystery", hardcover_requests.last[:variables]["query"]
  end

  test "an author page lists written books and explains hidden records" do
    stub_hardcover_graphql(
      "ShelfarrAuthor" => { "authors" => [ { "id" => 501, "name" => "Ada Writer", "slug" => "ada-writer", "books_count" => 3 } ] },
      "ShelfarrAuthorContributions" => { "contributions" => [
        hardcover_contribution_row(hardcover_book(id: 1, title: "Her Novel"), id: 1),
        hardcover_contribution_row(hardcover_book(id: 2, title: "Anthology She Edited"), id: 2, contribution: "Editor")
      ] }
    )

    get discover_author_path(501)

    assert_response :success
    assert_includes response.body, "Her Novel"
    assert_not_includes response.body, "Anthology She Edited"
    assert_includes response.body, "Hidden: 1 record"
    assert_select "form[action='#{hardcover_subscriptions_path}'] input[name=kind][value=author]"
  end

  test "rate limits and errors are shown without crashing" do
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 429, headers: { "Retry-After" => "120" }, body: "{}")

    get discover_lists_path

    assert_response :success
    assert_includes response.body, "rate limit"
  ensure
    HardcoverClient.send(:local_rate_limit_deadlines).clear
  end

  test "invalid ids are rejected" do
    get discover_list_path("not-a-number")

    assert_redirected_to discover_path
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "without any Hardcover credential the page explains how to enable discovery" do
    SettingsService.set(:hardcover_api_token, "")

    get discover_path

    assert_response :success
    assert_includes response.body, "Discovery needs Hardcover access"
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "is unavailable when Hardcover is disabled" do
    SettingsService.set(:hardcover_enabled, false)

    get discover_path

    assert_redirected_to search_path
  end
end
