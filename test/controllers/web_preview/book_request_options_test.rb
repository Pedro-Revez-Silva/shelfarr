# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::BookRequestOptionsTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  WORK = "openlibrary:OL900W"
  DETAILS = { title: "Middlemarch", author: "George Eliot" }.freeze

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ users(:one), users(:two) ].map { |user| user.id.to_s }.join(",")
    SettingsService.set(:auto_select_enabled, false)
    SettingsService.set(:enabled_languages, %w[en de fr])
    SettingsService.set(:default_language, "en")
    @member = users(:one)
    @admin = users(:two)
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @requests_before = Request.count
    @request_ids_before = Request.ids
  end

  teardown do
    Rails.cache = @previous_cache
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def book_json(user: @member)
    preview_get web_preview_api_book_path(source: "openlibrary", source_id: "OL900W"), user: user
    assert_response :success
    response.parsed_body.fetch("book")
  end

  def request_book(user: @member, body: {})
    BookMetadataLookupService.stub(:call, DETAILS) do
      post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: body, headers: account_headers(user), as: :json
    end
    response.parsed_body
  end

  def state_of(book, type)
    book.fetch("formats").find { |entry| entry.fetch("book_type") == type }.fetch("state")
  end

  def new_requests
    Request.where.not(id: @request_ids_before).order(:id).includes(:book).to_a
  end

  def created_rows
    new_requests.map { |request| [ request.user, request.book.book_type, request.language, request.notes, request.created_via, request.status ] }
  end

  test "the Book page and Find answer the server's default format, the enabled languages with the default, and the note limit" do
    SettingsService.set(:default_request_format, "both")
    SettingsService.set(:default_language, "nl")
    sign_in_as(@member)
    expected = { "formats" => %w[audiobook ebook], "default_format" => "both", "default_language" => "nl", "note_limit" => 1_000,
      "languages" => [ [ "nl", "Dutch" ], [ "en", "English" ], [ "fr", "French" ], [ "de", "German" ] ].map { |code, name| { "code" => code, "name" => name } } }
    assert_equal expected, BookMetadataLookupService.stub(:call, DETAILS) { book_json }.fetch("request_options")

    MetadataService.stub(:enabled_metadata_providers, []) do
      MetadataService.stub(:each_provider_search, ->(*_args, **_options) { }) do
        preview_get web_preview_api_discover_path(q: "middlemarch"), user: @member
      end
    end
    assert_equal expected, response.parsed_body.fetch("request_options")
  end

  test "a request with no body still asks for the ebook in the server's default language with no note" do
    sign_in_as(@member)
    answer = request_book(body: {})
    assert_response :created
    assert_equal [ "created", [ { "book_type" => "ebook", "outcome" => "created" } ] ], answer.values_at("outcome", "results")
    assert_equal [ [ @member, "ebook", "en", nil, "web", "pending" ] ], created_rows
    assert_equal [ "requested", "requestable" ], %w[ebook audiobook].map { |type| state_of(answer.fetch("book"), type) }
  end

  test "a member requests the audiobook with a chosen language and a note, and the ebook stays requestable" do
    sign_in_as(@member)
    answer = request_book(body: { book_type: "audiobook", language: "de", notes: "  Unabridged, please.  " })
    assert_response :created
    assert_equal [ { "book_type" => "audiobook", "outcome" => "created" } ], answer.fetch("results")
    assert_equal [ [ @member, "audiobook", "de", "Unabridged, please.", "web", "pending" ] ], created_rows
    assert_equal [ "requestable", "requested" ], %w[ebook audiobook].map { |type| state_of(answer.fetch("book"), type) }
  end

  test "both formats are requested together once, and pressing again makes nothing new" do
    sign_in_as(@member)
    answer = request_book(body: { book_type: "both", notes: "Either edition" })
    assert_response :created
    assert_equal [ { "book_type" => "audiobook", "outcome" => "created" }, { "book_type" => "ebook", "outcome" => "created" } ], answer.fetch("results")
    assert_equal [ [ @member, "audiobook", "en", "Either edition", "web", "pending" ], [ @member, "ebook", "en", "Either edition", "web", "pending" ] ], created_rows

    again = assert_no_difference("Request.count") { request_book(body: { book_type: "both" }) }
    assert_response :success
    assert_equal [ "existing", %w[existing existing] ], [ again.fetch("outcome"), again.fetch("results").map { |result| result.fetch("outcome") } ]
    assert_no_difference("Request.count") { request_book(body: { book_type: "audiobook", language: "fr" }) }
    assert_equal "existing", response.parsed_body.fetch("outcome")
  end

  test "both formats with the ebook already on the shelf requests only the audiobook" do
    Book.create!(title: "Middlemarch", author: "George Eliot", book_type: :ebook, open_library_work_id: "OL900W", file_path: @epub_path)
    sign_in_as(@member)
    answer = request_book(body: { book_type: "both" })
    assert_response :created
    assert_equal [ { "book_type" => "audiobook", "outcome" => "created" }, { "book_type" => "ebook", "outcome" => "existing" } ], answer.fetch("results")
    assert_equal [ [ @member, "audiobook", "en", nil, "web", "pending" ] ], created_rows
    assert_equal [ "in_library", "requested" ], %w[ebook audiobook].map { |type| state_of(answer.fetch("book"), type) }
  end

  test "both formats where one is refused by request creation reports that format's reason beside the one that was made" do
    sign_in_as(@member)
    refusing = lambda do |**arguments|
      assert_equal %w[audiobook ebook], arguments.fetch(:book_types)
      book = Book.create!(title: "Middlemarch", book_type: :audiobook, open_library_work_id: "OL900W")
      request = Request.create!(book: book, user: @member, status: :pending)
      RequestCreationService::Result.new(created_requests: [ request ], warnings: [], errors: [ "Middlemarch Ebook: This ebook is blocked from being acquired again" ])
    end
    answer = RequestCreationService.stub(:call, refusing) { request_book(body: { book_type: "both" }) }
    assert_response :created
    assert_equal [ { "book_type" => "audiobook", "outcome" => "created" },
      { "book_type" => "ebook", "outcome" => "rejected", "message" => "Middlemarch Ebook: This ebook is blocked from being acquired again" } ], answer.fetch("results")

    refused = ->(**) { RequestCreationService::Result.new(created_requests: [], warnings: [], errors: [ "Middlemarch Audiobook: Not today" ]) }
    Request.destroy_all
    sign_in_as(@admin)
    RequestCreationService.stub(:call, refused) { request_book(user: @admin, body: { book_type: "audiobook" }) }
    assert_response :unprocessable_entity
    assert_equal({ "error" => "request_rejected", "message" => "Middlemarch Audiobook: Not today" }, response.parsed_body)
  end

  test "a format, language or note the server does not offer is refused before anything is requested" do
    sign_in_as(@member)
    [
      { book_type: "comicbook" }, { book_type: "unknown" }, { book_type: nil }, { book_type: [ "ebook" ] }, { book_type: "Ebook" },
      { book_type: "ebook", language: "ja" }, { book_type: "ebook", language: "" }, { book_type: "ebook", language: [ "en" ] },
      { book_type: "ebook", notes: "x" * 1_001 }, { book_type: "ebook", notes: { text: "hi" } }, { language: "xx" }
    ].each do |body|
      assert_no_difference("Request.count", body.inspect) { request_book(body: body) }
      assert_response :unprocessable_entity
      assert_equal({ "error" => "invalid_request" }, response.parsed_body, body.inspect)
    end
    request_book(body: { book_type: "ebook", notes: "x" * 1_000 })
    assert_response :created
  end

  test "requesting keeps the existing approval and search policy for members and administrators" do
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:auto_approve_requests, false)
    sign_in_as(@member)
    assert_no_enqueued_jobs(only: SearchJob) { request_book(body: { book_type: "audiobook" }) }
    assert_response :created

    SettingsService.set(:auto_approve_requests, true)
    assert_enqueued_jobs(1, only: SearchJob) { request_book(body: { book_type: "ebook" }) }
    assert_response :created

    sign_in_as(@admin)
    Request.destroy_all
    assert_no_enqueued_jobs(only: SearchJob) { request_book(user: @admin, body: { book_type: "both" }) }
    assert_response :created
    SettingsService.set(:immediate_search_enabled, true)
    Request.destroy_all
    assert_enqueued_jobs(2, only: SearchJob) { request_book(user: @admin, body: { book_type: "both" }) }
  end

  test "another account's open request for a format leaves only the other format to request" do
    other = Book.create!(title: "Middlemarch", book_type: :audiobook, open_library_work_id: "OL900W")
    Request.create!(book: other, user: @admin, status: :pending)
    @request_ids_before = Request.ids
    sign_in_as(@member)
    answer = request_book(body: { book_type: "both" })
    assert_equal [ { "book_type" => "audiobook", "outcome" => "existing" }, { "book_type" => "ebook", "outcome" => "created" } ], answer.fetch("results")
    assert_equal [ [ @member, "ebook", "en", nil, "web", "pending" ] ], created_rows
    assert_equal "requested_by_someone", state_of(answer.fetch("book"), "audiobook")
    assert_no_match(/#{@admin.name}/, response.body) if @admin.name.present?
  end

  test "two presses that arrive together make each request once" do
    sign_in_as(@member)
    cookie = cookies["session_id"]
    slow_lookup = ->(*) { sleep 0.2; DETAILS }
    answers = BookMetadataLookupService.stub(:call, slow_lookup) do
      2.times.map do
        Thread.new do
          session = open_session
          session.cookies["session_id"] = cookie
          session.post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "both" }, headers: account_headers(@member), as: :json
          [ session.response.status, session.response.parsed_body.fetch("outcome") ]
        end
      end.map(&:value)
    end
    assert_equal [ [ 200, "existing" ], [ 201, "created" ] ], answers.sort
    assert_equal [ [ @member, "audiobook", "en", nil, "web", "pending" ], [ @member, "ebook", "en", nil, "web", "pending" ] ], created_rows
  end

  test "a comic's Book page offers no book format, and asking for one anyway is refused" do
    sign_in_as(@member)
    found = BookMetadataLookupService.stub(:call, DETAILS) do
      preview_get web_preview_api_book_path(source: "comic_vine", source_id: "4000-77"), user: @member
      response.parsed_body.fetch("book")
    end
    assert_equal [], found.dig("request_options", "formats")
    [ {}, { book_type: "ebook" }, { book_type: "audiobook" }, { book_type: "both" } ].each do |body|
      BookMetadataLookupService.stub(:call, DETAILS) do
        post web_preview_api_book_requests_path(source: "comic_vine", source_id: "4000-77"), params: body, headers: account_headers(@member), as: :json
      end
      assert_equal [ 422, { "error" => "invalid_request" } ], [ response.status, response.parsed_body ], body.inspect
    end
    assert_equal 0, Request.count - @requests_before
  end

  test "an administrator demoted while the request is made gets the member's answer, and a session ended meanwhile is told it is signed out" do
    other = Book.create!(title: "Middlemarch", book_type: :ebook, open_library_work_id: "OL900W")
    Request.create!(book: other, user: @member, status: :pending)
    sign_in_as(@admin)
    demoting = ->(*) { @admin.update!(role: :user); DETAILS }
    answer = BookMetadataLookupService.stub(:call, demoting) do
      post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "audiobook" }, headers: account_headers(@admin), as: :json
      response.parsed_body
    end
    assert_response :created
    assert_equal({ "book_type" => "ebook", "state" => "requested_by_someone", "publication" => nil, "request" => nil }, answer.fetch("book").fetch("formats").find { |entry| entry.fetch("book_type") == "ebook" })
    assert_no_match(/#{Regexp.escape(@member.name.to_s)}/, response.body) if @member.name.present?

    Request.destroy_all
    Book.where(open_library_work_id: "OL900W").destroy_all
    session = Current.session
    ending = ->(*) { session.destroy!; DETAILS }
    assert_no_difference("Request.count") do
      BookMetadataLookupService.stub(:call, ending) do
        post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "audiobook" }, headers: account_headers(@admin), as: :json
      end
    end
    assert_equal [ 401, { "error" => "signed_out" } ], [ response.status, response.parsed_body ]
  end

  test "a stored graphic work offers no book format whatever catalogue address it has, and Find leaves it out" do
    Book.create!(title: "Middlemarch: The Graphic Novel", book_type: :comicbook, content_kind: :graphic, open_library_work_id: "OL900W")
    sign_in_as(@member)
    found = OpenLibraryClient::SearchResult.new(work_id: "OL900W", title: "Middlemarch", author: "George Eliot", first_publish_year: 1871, cover_id: nil, edition_count: 3)
    hits = [ MetadataSearch::ResultNormalizer.call("openlibrary", found, requested_content_kind: ContentKinds::BOOK) ]
    search = ->(*_args, **_options, &each) { each.call("openlibrary", hits, false) }
    MetadataService.stub(:enabled_metadata_providers, [ "openlibrary" ]) do
      MetadataService.stub(:each_provider_search, search) { preview_get web_preview_api_discover_path(q: "middlemarch"), user: @member }
    end
    assert_equal [ 200, [] ], [ response.status, response.parsed_body.fetch("items") ]
    assert_equal [], BookMetadataLookupService.stub(:call, DETAILS) { book_json }.dig("request_options", "formats")
    assert_no_difference("Request.count") { request_book(body: { book_type: "audiobook" }) }
    assert_equal [ 422, { "error" => "invalid_request" } ], [ response.status, response.parsed_body ]
  end

  test "choosing a format still needs the page's account and CSRF token" do
    sign_in_as(@member)
    post web_preview_api_book_requests_path(source: "openlibrary", source_id: "OL900W"), params: { book_type: "audiobook" }, headers: account_headers(@admin), as: :json
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    with_forgery_protection do
      request_book(body: { book_type: "audiobook" })
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
    sign_out
    request_book(body: { book_type: "audiobook" })
    assert_response :unauthorized
    assert_equal "signed_out", response.parsed_body.fetch("error")
    assert_equal 0, Request.count - @requests_before
  end
end
