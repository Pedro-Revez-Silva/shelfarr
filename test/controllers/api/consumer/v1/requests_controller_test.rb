# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

class API::Consumer::V1::RequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ConsumerTestHelper

  setup do
    prepare_consumer_library
    _, raw = APIToken.issue!(name: "Shelfarr Android", user: users(:one),
      scopes: ConsumerDeviceGrant::SCOPES + ConsumerDeviceGrant::REQUEST_SCOPES, issued_via: APIToken::CONSUMER_DEVICE)
    @requesting = { "Authorization" => "Bearer #{raw}" }
    clear_enqueued_jobs
  end

  teardown { FileUtils.remove_entry(@root) }

  def request_body(**overrides)
    { work_id: "openlibrary:OL_NATIVE_1W", book_type: "ebook", title: "A Native Request", author: "An Author",
      cover_url: "https://covers.example/1.jpg", year: 2001, source_work_ids: [ "google_books:native1" ] }.merge(overrides)
  end

  def search_result(id, title, **attrs)
    MetadataService::SearchResult.new(source: "openlibrary", source_id: id, title: title, author: "Search Author",
      description: "About #{title}", year: 2001, cover_url: "http://insecure.example/c.jpg", has_audiobook: nil, has_ebook: nil,
      series_name: nil, series_position: nil, **attrs)
  end

  test "creates the account's own request through the shared request service and follows it to the acquired publication" do
    assert_difference "Request.count", 1 do
      post "/api/consumer/v1/requests", params: request_body, headers: @requesting, as: :json
    end
    assert_response :created
    view = response.parsed_body.fetch("request")
    assert_equal "queued", view.fetch("stage")
    assert_equal "ebook", view.fetch("book_type")
    assert_nil view.fetch("publication_id")
    assert view.fetch("can_cancel")
    request = Request.find(view.fetch("id"))
    assert_equal users(:one), request.user
    assert_equal "api", request.created_via
    assert_equal "consumer_app", request.external_source

    request.update!(status: :downloading)
    request.downloads.create!(status: :downloading, progress: 42, name: "release")
    get "/api/consumer/v1/requests/#{request.id}", headers: @requesting
    assert_equal "downloading", response.parsed_body.dig("request", "stage")
    assert_equal 42, response.parsed_body.dig("request", "download_percent")

    request.downloads.update_all(status: Download.statuses[:completed])
    request.book.update!(file_path: @epub_path)
    request.update!(status: :completed)
    get "/api/consumer/v1/requests", headers: @requesting
    item = response.parsed_body.fetch("items").find { |entry| entry.fetch("id") == request.id.to_s }
    assert_equal "available", item.fetch("stage")
    assert_equal request.book_id.to_s, item.fetch("publication_id")
    get "/api/consumer/v1/library/#{item.fetch('publication_id')}", headers: @requesting
    assert_response :success
    assert_equal "epub", response.parsed_body.fetch("assets").sole.fetch("format")
  end

  test "repeated taps return the same request instead of a duplicate" do
    post "/api/consumer/v1/requests", params: request_body, headers: @requesting, as: :json
    first = response.parsed_body.dig("request", "id")
    assert_no_difference "Request.count" do
      3.times do
        post "/api/consumer/v1/requests", params: request_body, headers: @requesting, as: :json
        assert_response :ok
        assert_equal first, response.parsed_body.dig("request", "id")
        assert response.parsed_body.fetch("existing")
      end
    end
  end

  test "concurrent duplicate submissions create one request" do
    threads = Array.new(4) do
      Thread.new do
        Rails.application.executor.wrap do
          integration = ActionDispatch::Integration::Session.new(Rails.application)
          integration.post "/api/consumer/v1/requests", params: request_body.to_json,
            headers: @requesting.merge("Content-Type" => "application/json")
          integration.response.status
        end
      end
    end
    statuses = threads.map(&:value)
    assert_equal 1, Request.joins(:book).where(books: { title: "A Native Request" }).count
    assert_equal [ 200, 200, 200, 201 ], statuses.sort
  end

  test "titles already in the library or requested by someone else are explained without exposing the other request" do
    @ebook.update!(open_library_work_id: "OL_IN_LIBRARY_W")
    post "/api/consumer/v1/requests", params: request_body(work_id: "openlibrary:OL_IN_LIBRARY_W", source_work_ids: []), headers: @requesting, as: :json
    assert_response :conflict
    assert_equal "already_in_library", response.parsed_body.fetch("error")
    assert_equal @ebook.id.to_s, response.parsed_body.fetch("publication_id")

    book = Book.create!(title: "Wanted elsewhere", book_type: :audiobook, open_library_work_id: "OL_ELSEWHERE_W")
    Request.create!(user: users(:two), book: book, status: :searching)
    post "/api/consumer/v1/requests", params: request_body(work_id: "openlibrary:OL_ELSEWHERE_W", book_type: "audiobook", source_work_ids: []), headers: @requesting, as: :json
    assert_response :conflict
    assert_equal "already_requested", response.parsed_body.fetch("error")
    assert_not_includes response.body, users(:two).username
  end

  test "malformed input, other formats and on-behalf fields are refused" do
    [
      request_body(book_type: "comicbook"), request_body(book_type: "both"), request_body(work_id: ""),
      request_body(work_id: "no-provider"), request_body(title: ""), request_body(title: "x" * 501),
      request_body(year: "2001"), request_body(source_work_ids: "openlibrary:OL2W"), request_body(author: { a: 1 })
    ].each do |body|
      assert_no_difference "Request.count" do
        post "/api/consumer/v1/requests", params: body, headers: @requesting, as: :json
      end
      assert_response :unprocessable_entity, body.inspect
    end

    post "/api/consumer/v1/requests", params: request_body(username: users(:two).username, user_id: users(:two).id), headers: @requesting, as: :json
    assert_response :created
    assert_equal users(:one), Request.find(response.parsed_body.dig("request", "id")).user
  end

  test "insecure covers are dropped and comic results are not offered" do
    graphic = MetadataSearch::Candidate.new(canonical_key: "comic_vine:4000-1", title: "A Comic", author: nil, year: nil, description: nil,
      cover_url: nil, series_name: nil, series_position: nil, has_ebook: nil, has_audiobook: nil, editions: [], confidence: 90,
      content_kind: "graphic", sources: [ { source: "comic_vine", source_id: "4000-1", work_id: "comic_vine:4000-1" } ])
    MetadataService.stub(:search, [ search_result("OL_SEARCH_1W", "Searchable"), graphic ]) do
      get "/api/consumer/v1/discover", params: { q: "searchable" }, headers: @requesting
    end
    assert_response :success
    items = response.parsed_body.fetch("items")
    assert_equal [ "Searchable" ], items.map { |item| item.fetch("title") }
    assert_nil items.first.fetch("cover_url")
    assert_equal %w[ebook audiobook], items.first.fetch("formats").map { |format| format.fetch("book_type") }
    assert_equal %w[requestable requestable], items.first.fetch("formats").map { |format| format.fetch("state") }
  end

  test "discover marks each format as in the library, already requested by me, or requested by someone else" do
    @ebook.update!(open_library_work_id: "OL_MIXED_W")
    Request.create!(user: users(:one), book: Book.create!(title: "Mine", book_type: :audiobook, open_library_work_id: "OL_MIXED_W"), status: :searching)
    Request.create!(user: users(:two), book: Book.create!(title: "Theirs", book_type: :audiobook, open_library_work_id: "OL_OTHER_W"), status: :pending)
    MetadataService.stub(:search, [ search_result("OL_MIXED_W", "Mixed"), search_result("OL_OTHER_W", "Other") ]) do
      get "/api/consumer/v1/discover", params: { q: "mixed" }, headers: @requesting
    end
    mixed, other = response.parsed_body.fetch("items")
    ebook, audio = mixed.fetch("formats")
    assert_equal [ "in_library", @ebook.id.to_s ], [ ebook.fetch("state"), ebook.fetch("publication_id") ]
    assert_equal "requested", audio.fetch("state")
    assert_equal "searching", audio.dig("request", "stage")
    assert_equal "requested_by_someone", other.fetch("formats").last.fetch("state")
    assert_nil other.fetch("formats").last.fetch("request")
  end

  test "empty, invalid and failing searches are distinguishable" do
    MetadataService.stub(:search, []) do
      get "/api/consumer/v1/discover", params: { q: "nothing" }, headers: @requesting
    end
    assert_equal({ "items" => [] }, response.parsed_body)
    [ "", " ", "x" * 201 ].each do |query|
      get "/api/consumer/v1/discover", params: { q: query }, headers: @requesting
      assert_response :unprocessable_entity
    end
    MetadataService.stub(:search, ->(*) { raise OpenLibraryClient::ConnectionError, "down" }) do
      get "/api/consumer/v1/discover", params: { q: "down" }, headers: @requesting
    end
    assert_response :service_unavailable
    assert_equal "search_unavailable", response.parsed_body.fetch("error")
  end

  test "cancelling works only on the account's own cancellable requests" do
    post "/api/consumer/v1/requests", params: request_body, headers: @requesting, as: :json
    id = response.parsed_body.dig("request", "id")
    delete "/api/consumer/v1/requests/#{id}", headers: @requesting
    assert_response :success
    assert_equal "failed", response.parsed_body.dig("request", "stage")

    theirs = Request.create!(user: users(:two), book: Book.create!(title: "Theirs", book_type: :ebook), status: :pending)
    delete "/api/consumer/v1/requests/#{theirs.id}", headers: @requesting
    assert_response :not_found
    assert theirs.reload.pending?

    done = Request.create!(user: users(:one), book: @ebook, status: :completed)
    delete "/api/consumer/v1/requests/#{done.id}", headers: @requesting
    assert_response :unprocessable_entity
    assert_equal "cannot_cancel", response.parsed_body.fetch("error")
  end

  test "read-only connections and wrong scopes cannot search or request" do
    get "/api/consumer/v1/requests", headers: @headers
    assert_response :forbidden
    assert_equal "requests:read", response.parsed_body.fetch("required_scope")
    post "/api/consumer/v1/requests", params: request_body, headers: @headers, as: :json
    assert_response :forbidden
    _, read_only = APIToken.issue!(name: "Reader", user: users(:one), scopes: %w[library:read requests:read])
    post "/api/consumer/v1/requests", params: request_body, headers: { "Authorization" => "Bearer #{read_only}" }, as: :json
    assert_response :forbidden
    assert_equal "requests:write", response.parsed_body.fetch("required_scope")
    SettingsService.set(:api_token, "legacy-global-token")
    get "/api/consumer/v1/requests", headers: { "Authorization" => "Bearer legacy-global-token" }
    assert_response :unauthorized
  end
end
