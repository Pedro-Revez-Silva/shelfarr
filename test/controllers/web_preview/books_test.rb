# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::BooksTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  WORK = "openlibrary:OL900W"

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ users(:one), users(:two) ].map { |user| user.id.to_s }.join(",")
    SettingsService.set(:auto_select_enabled, false)
    @member = users(:one)
    @admin = users(:two)
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def catalogue_result(work_id: WORK, title: "Middlemarch", author: "George Eliot")
    _, source_id = Book.parse_work_id(work_id)
    found = OpenLibraryClient::SearchResult.new(work_id: source_id, title: title, author: author, first_publish_year: 1871, cover_id: nil, edition_count: 3)
    MetadataSearch::ResultNormalizer.call("openlibrary", found, requested_content_kind: ContentKinds::BOOK)
  end

  def with_catalogue(answers, &block)
    providers = answers.keys
    search = lambda do |*_args, **_options, &each|
      answers.each { |provider, (results, failed)| each.call(provider, results, failed) }
    end
    MetadataService.stub(:enabled_metadata_providers, providers) { MetadataService.stub(:each_provider_search, search, &block) }
  end

  def discover(query, user:)
    preview_get web_preview_api_discover_path(q: query), user: user
    assert_response :success
    response.parsed_body
  end

  def book_json(user:, source: "openlibrary", id: "OL900W", **params)
    preview_get web_preview_api_book_path(source: source, source_id: id, **params), user: user
    assert_response :success
    response.parsed_body.fetch("book")
  end

  def format_of(book, type)
    book.fetch("formats").find { |entry| entry.fetch("book_type") == type }
  end

  def request_ebook(user:, **params)
    post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W", **params), headers: account_headers(user), as: :json
  end

  def requested_middlemarch(status: :searching, user: @member)
    book = Book.create!(title: "Middlemarch", author: "George Eliot", book_type: :ebook, open_library_work_id: "OL900W")
    request = Request.create!(book: book, user: user, status: status)
    copies = [
      [ "Middlemarch (with illustrations)", 1_900_000, "epub", "en" ],
      [ "Middlemarch (text edition)", 900_000, "epub", "en" ]
    ].map.with_index do |(title, size, extension, language), index|
      request.search_results.create!(guid: "copy-#{index}", title: title, size_bytes: size, detected_language: language, source: SearchResult::SOURCE_GUTENBERG,
        download_url: "https://files.example.test/#{index}.epub", info_url: "https://files.example.test/info/#{index}", score_breakdown: { "extension" => extension }, confidence_score: 90 - index)
    end
    [ request, copies ]
  end

  test "discover answers each catalogue result with its Book page address and per-format state for this account" do
    shelved = Book.create!(title: "Owned", author: "A. Reader", book_type: :ebook, open_library_work_id: "OL901W", file_path: @epub_path)
    sign_in_as(@member)
    with_catalogue("openlibrary" => [ [ catalogue_result, catalogue_result(work_id: "openlibrary:OL901W", title: "Owned") ], false ]) do
        body = discover("middlemarch", user: @member)
        assert_equal [ "account", "items", "providers", "query", "unavailable" ], body.keys.sort
        assert_equal [ [ "Open Library" ], [] ], body.values_at("providers", "unavailable")
        first, owned = body.fetch("items")
        assert_equal({ "source" => "openlibrary", "id" => "OL900W" }, first.fetch("book").except("metadata"))
        assert_match(/\A[A-Za-z0-9_-]{32}\z/, first.dig("book", "metadata"))
        assert_equal [ "Middlemarch", "George Eliot", 1871, "Open Library" ], first.values_at("title", "author", "year", "source_name")
        assert_equal [ { "book_type" => "ebook", "state" => "requestable" }, { "book_type" => "audiobook", "state" => "requestable" } ], first.fetch("formats")
        assert_equal "in_library", owned.fetch("formats").first.fetch("state")
        assert_not_nil shelved
    end
  end

  test "discover says which catalogues failed, and a search where every catalogue failed is not shown as no matches" do
    sign_in_as(@member)
    with_catalogue("hardcover" => [ [], true ], "openlibrary" => [ [ catalogue_result ], false ]) do
      body = discover("middlemarch", user: @member)
      assert_equal [ [ "Hardcover", "Open Library" ], [ "Hardcover" ], [ "Middlemarch" ] ], [ body.fetch("providers"), body.fetch("unavailable"), body.fetch("items").map { |item| item.fetch("title") } ]
    end
    with_catalogue("openlibrary" => [ [], true ]) do
      preview_get web_preview_api_discover_path(q: "middlemarch"), user: @member
      assert_response :service_unavailable
      assert_equal "search_unavailable", response.parsed_body.fetch("error")
    end
  end

  test "discover says when no catalogue is switched on and refuses a malformed query" do
    sign_in_as(@member)
    MetadataService.stub(:enabled_metadata_providers, []) do
      assert_equal({ "account" => @member.id.to_s, "query" => "middlemarch", "providers" => [], "unavailable" => [], "items" => [] }, discover("middlemarch", user: @member))
    end
    preview_get web_preview_api_discover_path(q: "a\u0007b"), user: @member
    assert_response :unprocessable_entity
    assert_equal "invalid_query", response.parsed_body.fetch("error")
  end

  test "a catalogue work opens from its discover hand-off with separate ebook and audiobook rows and no request" do
    sign_in_as(@member)
    token = nil
    with_catalogue("openlibrary" => [ [ catalogue_result ], false ]) { token = discover("middlemarch", user: @member).dig("items", 0, "book", "metadata") }
    book = BookMetadataLookupService.stub(:call, { title: "Not this title", author: "Not this author", description: "Lives in a provincial town." }) { book_json(user: @member, metadata: token) }
    assert_equal({ "id" => WORK, "also" => [], "details" => "catalogue", "title" => "Middlemarch", "author" => "George Eliot", "year" => 1871,
      "description" => "Lives in a provincial town.", "cover" => { "url" => nil, "style" => WebPreview::BookPage.cover_style(WORK) },
      "source" => { "name" => "Open Library", "url" => "https://openlibrary.org/works/OL900W" },
      "formats" => %w[ebook audiobook].map { |type| { "book_type" => type, "state" => "requestable", "publication" => nil, "request" => nil } } }, book)
  end

  test "a hand-off without a description keeps its own details and takes only the missing ones from the catalogue" do
    sign_in_as(@member)
    token = WebPreview::BookHandoff.store(user: @member, details: { work_id: WORK, title: "Middlemarch", author: "George Eliot", year: 1871 })
    book = BookMetadataLookupService.stub(:call, { title: "Middlemarch: A Study", author: "G. Eliot", description: "Lives in a provincial town." }) { book_json(user: @member, metadata: token) }
    assert_equal [ "Middlemarch", "George Eliot", 1871, "Lives in a provincial town." ], book.values_at("title", "author", "year", "description")
  end

  test "without a hand-off the work's details come from the catalogue, and an unreachable catalogue is said plainly" do
    sign_in_as(@member)
    found = BookMetadataLookupService.stub(:call, { title: "Middlemarch", author: "George Eliot", year: 1871 }) { book_json(user: @member) }
    assert_equal [ "catalogue", "Middlemarch" ], found.values_at("details", "title")
    missing = BookMetadataLookupService.stub(:call, ->(*) { raise OpenLibraryClient::ConnectionError, "offline" }) { book_json(user: @member) }
    assert_equal [ "missing", nil ], missing.values_at("details", "title")
    request_ebook(user: @member)
    assert_response :unprocessable_entity
    assert_equal "request_rejected", response.parsed_body.fetch("error")
    assert_equal 0, Request.count - requests_before_test
  end

  def requests_before_test
    @requests_before_test ||= Request.count
  end

  test "requesting the ebook goes through request creation once, queues the search, and the page then shows the member's own request" do
    sign_in_as(@member)
    requests_before_test
    BookMetadataLookupService.stub(:call, { title: "Middlemarch", author: "George Eliot" }) do
      assert_enqueued_with(job: SearchJob) { request_ebook(user: @member) }
      assert_response :created
      assert_equal "created", response.parsed_body.fetch("outcome")
      request_ebook(user: @member)
      assert_response :success
      assert_equal "existing", response.parsed_body.fetch("outcome")
    end
    assert_equal 1, Request.count - requests_before_test
    request = Request.order(:id).last
    assert_equal [ @member, "ebook", "OL900W", "web" ], [ request.user, request.book.book_type, request.book.open_library_work_id, request.created_via ]
    ebook = format_of(book_json(user: @member), "ebook")
    assert_equal "requested", ebook.fetch("state")
    assert_equal({ "id" => request.id.to_s, "status" => "pending", "stage" => "queued", "attention_needed" => false, "download_percent" => nil,
      "can_cancel" => true, "next_retry_at" => nil, "created_at" => request.created_at.iso8601, "updated_at" => request.updated_at.iso8601,
      "own" => true, "choice_needed" => false }, ebook.fetch("request"))
    assert_equal "requestable", format_of(book_json(user: @member), "audiobook").fetch("state")
  end

  test "a member sees that copies wait for an administrator but never their titles, sources or another account's request" do
    request, = requested_middlemarch
    sign_in_as(@member)
    own = format_of(book_json(user: @member), "ebook").fetch("request")
    assert_equal [ true, true ], own.values_at("own", "choice_needed")
    assert_not_includes response.body, "with illustrations"
    assert_not_includes response.body, "Gutenberg"
    assert_not_includes response.body, "files.example.test"
    assert_nil own["copies"]

    request.update!(user: @admin)
    other = format_of(book_json(user: @member), "ebook")
    assert_equal({ "book_type" => "ebook", "state" => "requested_by_someone", "publication" => nil, "request" => nil }, other)
    assert_not_includes response.body, @admin.name
  end

  test "an administrator sees each stored copy with format, size, language and source, and no download address" do
    request, copies = requested_middlemarch
    sign_in_as(@admin)
    ebook = format_of(book_json(user: @admin), "ebook").fetch("request")
    assert_equal [ false, "User One" ], ebook.values_at("own", "requested_by")
    assert_equal({ "selectable" => true, "can_search_again" => true, "candidates" => copies.map { |copy|
      { "id" => copy.id.to_s, "title" => copy.title, "format" => "EPUB", "size_bytes" => copy.size_bytes, "language" => "English", "source" => "Project Gutenberg",
        "state" => "pending", "skipped" => false, "downloadable" => true }
    } }, ebook.fetch("copies"))
    assert_not_includes response.body, "files.example.test"
    assert request.needs_manual_selection?
  end

  test "only an administrator can choose a copy, and choosing one starts the existing download job" do
    request, copies = requested_middlemarch
    sign_in_as(@member)
    post web_preview_api_request_selection_path(request), params: { result_id: copies.last.id.to_s }, headers: account_headers(@member), as: :json
    assert_response :not_found
    assert request.reload.searching?

    sign_in_as(@admin)
    assert_enqueued_with(job: DownloadJob) do
      post web_preview_api_request_selection_path(request), params: { result_id: copies.last.id.to_s }, headers: account_headers(@admin), as: :json
    end
    assert_response :success
    assert_equal({ "account" => @admin.id.to_s, "request" => { "id" => request.id.to_s, "status" => "downloading" } }, response.parsed_body)
    assert_equal [ "rejected", "selected" ], copies.map { |copy| copy.reload.status }
    assert_equal "downloading", format_of(book_json(user: @admin), "ebook").dig("request", "stage")
  end

  test "a copy cannot be chosen once a download is queued, and a bad size is left out" do
    request, copies = requested_middlemarch
    copies.first.update!(size_bytes: -1)
    sign_in_as(@admin)
    assert_nil format_of(book_json(user: @admin), "ebook").dig("request", "copies", "candidates", 0, "size_bytes")
    request.downloads.create!(name: "queued", status: :queued, search_result: copies.first)
    assert_no_enqueued_jobs(only: DownloadJob) do
      post web_preview_api_request_selection_path(request), params: { result_id: copies.last.id.to_s }, headers: account_headers(@admin), as: :json
    end
    assert_response :conflict
    assert_equal [ "queued" ], request.downloads.reload.map(&:status)
    assert_equal false, format_of(book_json(user: @admin), "ebook").dig("request", "copies", "selectable")
  end

  test "after a chosen copy failed, an administrator can still choose another copy the request had set aside" do
    request, copies = requested_middlemarch
    copies.first.update!(status: :rejected)
    copies.last.update!(status: :rejected)
    request.downloads.create!(name: "failed", status: :failed, search_result: copies.first)
    request.update!(status: :not_found, attention_needed: true, issue_description: "Download failed: refused. Select another release manually.")
    sign_in_as(@admin)
    ebook = format_of(book_json(user: @admin), "ebook")
    assert_equal [ "requested", true, [ true, true ] ], [ ebook.fetch("state"), ebook.dig("request", "copies", "selectable"), ebook.dig("request", "copies", "candidates").map { |copy| copy.fetch("downloadable") } ]
    assert_enqueued_with(job: DownloadJob) do
      post web_preview_api_request_selection_path(request), params: { result_id: copies.last.id.to_s }, headers: account_headers(@admin), as: :json
    end
    assert_response :success
    assert_equal "downloading", request.reload.status
  end

  test "an administrator can search again, and a copy of another request cannot be chosen" do
    request, = requested_middlemarch
    stranger = Request.create!(book: Book.create!(title: "Other", book_type: :ebook, open_library_work_id: "OL902W"), user: @member, status: :searching)
    foreign = stranger.search_results.create!(guid: "foreign", title: "Other copy", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/x.epub")
    sign_in_as(@admin)
    post web_preview_api_request_selection_path(request), params: { result_id: foreign.id.to_s }, headers: account_headers(@admin), as: :json
    assert_response :not_found
    assert_enqueued_with(job: SearchJob, args: [ request.id ]) do
      post web_preview_api_request_search_path(request), headers: account_headers(@admin), as: :json
    end
    assert_response :success
    assert_equal "pending", request.reload.status
    assert_equal 0, request.search_results.count
  end

  test "a member cancels only their own request" do
    request, = requested_middlemarch
    request.update!(user: @admin)
    sign_in_as(@member)
    post web_preview_api_request_cancel_path(request), headers: account_headers(@member), as: :json
    assert_response :not_found
    request.update!(user: @member)
    post web_preview_api_request_cancel_path(request), headers: account_headers(@member), as: :json
    assert_response :success
    assert_equal "failed", request.reload.status
    assert_equal "requestable", format_of(book_json(user: @member), "ebook").fetch("state")
  end

  test "an acquired ebook found through the work's stored links opens in the existing reader, and the library detail links back to its Book page" do
    Book.create!(title: "The Quiet Library", book_type: :audiobook, hardcover_id: "77", google_books_id: "gb-1")
    @ebook.update!(google_books_id: "gb-1")
    sign_in_as(@member)
    book = book_json(user: @member, source: "hardcover", id: "77")
    assert_equal [ "library", "The Quiet Library", [ "google_books:gb-1" ] ], book.values_at("details", "title", "also")
    ebook = format_of(book, "ebook")
    assert_equal "in_library", ebook.fetch("state")
    assert_equal [ @ebook.id.to_s, "available", consumer_publication_path(@ebook), "Start reading" ], ebook.fetch("publication").values_at("id", "availability", "reader_url", "progress_label")
    request_ebook_for = -> { post web_preview_api_book_requests_path(source: "hardcover", source_id: "77"), headers: account_headers(@member), as: :json }
    assert_no_difference("Request.count") { request_ebook_for.call }

    preview_get "/preview/api/v1/library/#{@ebook.id}", user: @member
    assert_equal({ "source" => "google_books", "id" => "gb-1" }, response.parsed_body.dig("publication", "book_page"))
  end

  test "work links in the address are ignored, so a request cannot join unrelated works" do
    stranger = Book.create!(title: "Unrelated", author: "Someone", book_type: :audiobook, hardcover_id: "55", file_path: @audio_path)
    sign_in_as(@member)
    book = BookMetadataLookupService.stub(:call, { title: "Middlemarch", author: "George Eliot" }) { book_json(user: @member, also: "hardcover:55") }
    assert_equal [ "Middlemarch", [], "requestable" ], [ book.fetch("title"), book.fetch("also"), format_of(book, "audiobook").fetch("state") ]
    BookMetadataLookupService.stub(:call, { title: "Middlemarch", author: "George Eliot" }) { request_ebook(user: @member, also: "hardcover:55") }
    assert_response :created
    created = Request.order(:id).last.book
    assert_equal [ "OL900W", nil ], [ created.open_library_work_id, created.hardcover_id ]
    assert_nil stranger.reload.open_library_work_id
  end

  test "a hand-off Discover made groups the work by its links, a classic hand-off token is ignored, and a comic gets no Book page link" do
    Book.create!(title: "Middlemarch", book_type: :audiobook, hardcover_id: "88", file_path: @audio_path)
    sign_in_as(@member)
    token = WebPreview::BookHandoff.store(user: @member, details: { work_id: WORK, links: [ "hardcover:88" ], title: "Middlemarch", author: "George Eliot", description: "x" })
    book = book_json(user: @member, metadata: token)
    assert_equal [ [ "hardcover:88" ], "in_library" ], [ book.fetch("also"), format_of(book, "audiobook").fetch("state") ]
    classic = RequestMetadataHandoff.params_for(user: @member, metadata: { work_id: WORK, source_work_ids: [ WORK, "hardcover:88" ], title: "Middlemarch" })[:metadata_token]
    book = BookMetadataLookupService.stub(:call, {}) { book_json(user: @member, metadata: classic) }
    assert_equal [ [], "requestable", "missing" ], [ book.fetch("also"), format_of(book, "audiobook").fetch("state"), book.fetch("details") ]
    comic = Book.create!(title: "Comic", book_type: :comicbook, comic_vine_id: "4000-1", file_path: @epub_path)
    assert_nil WebPreview::BookPage.path_for(comic)
  end

  test "a request with a search still scheduled keeps the ebook taken for everyone, and no account sees another account's outcome" do
    request, = requested_middlemarch(status: :searching)
    request.search_results.destroy_all
    request.update!(status: :not_found, next_retry_at: 2.hours.from_now, user: @member)
    sign_in_as(@member)
    ebook = format_of(book_json(user: @member), "ebook")
    assert_equal [ "requested", "not_found", request.next_retry_at.iso8601 ], [ ebook.fetch("state"), ebook.dig("request", "stage"), ebook.dig("request", "next_retry_at") ]

    request.update!(user: @admin)
    other = BookMetadataLookupService.stub(:call, { title: "Middlemarch" }) { book_json(user: @member) }
    assert_equal({ "book_type" => "ebook", "state" => "requested_by_someone", "publication" => nil, "request" => nil }, format_of(other, "ebook"))
    assert_no_difference("Request.count") { BookMetadataLookupService.stub(:call, { title: "Middlemarch" }) { request_ebook(user: @member) } }
    assert_equal "existing", response.parsed_body.fetch("outcome")

    request.update!(status: :failed)
    assert_equal({ "book_type" => "ebook", "state" => "requestable", "publication" => nil, "request" => nil }, format_of(book_json(user: @member), "ebook"))
    assert_not_includes response.body, "failed"
  end

  test "an acquired ebook wins over an earlier placeholder for the same work, and no second request is made" do
    placeholder = Book.create!(title: "Middlemarch", book_type: :ebook, hardcover_id: "77")
    Request.create!(book: placeholder, user: @member, status: :failed)
    @ebook.update!(google_books_id: "gb-1")
    Book.create!(title: "Middlemarch", book_type: :audiobook, hardcover_id: "77", google_books_id: "gb-1")
    sign_in_as(@member)
    ebook = format_of(book_json(user: @member, source: "hardcover", id: "77"), "ebook")
    assert_equal [ "in_library", @ebook.id.to_s ], [ ebook.fetch("state"), ebook.dig("publication", "id") ]
    assert_no_difference("Request.count") { post web_preview_api_book_requests_path(source: "hardcover", source_id: "77"), headers: account_headers(@member), as: :json }
  end

  test "an acquired ebook whose file is gone is still on the shelf but cannot be opened" do
    @ebook.update!(open_library_work_id: "OL900W")
    File.unlink(@epub_path)
    sign_in_as(@member)
    publication = format_of(book_json(user: @member), "ebook").fetch("publication")
    assert_equal "unavailable", publication.fetch("availability")
  end

  test "the Book page and discover addresses load the preview shell, and the API keeps the account and access checks" do
    sign_in_as(@member)
    get "/preview/books/openlibrary/OL900W"
    assert_response :success
    assert_select "#shelfarr-boot"
    get "/preview/discover"
    assert_response :success
    get "/preview/books/elsewhere/OL900W"
    assert_response :not_found
    get web_preview_api_book_path(source: "openlibrary", source_id: "OL900W"), headers: { "Accept" => "application/json" }
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    sign_in_as(users(:one))
    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    preview_get web_preview_api_discover_path(q: "x"), user: @member
    assert_response :not_found
  end

  test "requesting needs the page's CSRF token" do
    sign_in_as(@member)
    with_forgery_protection do
      request_ebook(user: @member)
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
  end
end
