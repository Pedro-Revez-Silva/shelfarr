# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::LibraryControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ users(:one), users(:two) ].map { |user| user.id.to_s }.join(",")
    Book.where.not(id: [ @ebook.id, @audiobook.id ]).update_all(file_path: nil)
    sign_in_as(users(:one))
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def library_item(book)
    preview_get web_preview_api_library_path(q: book.title)
    assert_response :success
    response.parsed_body.fetch("items").sole
  end

  def listen_to_audiobook
    Consumer::ProgressWriter.new(user: users(:one), book: @audiobook).call(audio_progress.stringify_keys)
  end

  test "the library lists the account's acquired books with the complete browser representation" do
    preview_get web_preview_api_library_path
    assert_response :success
    body = response.parsed_body
    assert_equal [ "account", "items", "next_cursor" ], body.keys.sort
    assert_equal users(:one).id.to_s, body.fetch("account")
    assert_nil body.fetch("next_cursor")
    assert_equal [ @audiobook.id.to_s, @ebook.id.to_s ], body.fetch("items").map { |item| item.fetch("id") }
    assert_equal({ "id" => @ebook.id.to_s, "title" => "The Quiet Library", "author" => "A. Reader", "book_type" => "ebook", "content_kind" => "book",
      "format_label" => "Ebook", "availability" => "available", "action" => "read",
      "cover" => { "url" => nil, "style" => helper_cover_style(@ebook) }, "reading_status" => "unread", "progress" => nil,
      "progress_label" => "Start reading", "reader_url" => consumer_publication_path(@ebook) }, library_item(@ebook))
    audiobook = library_item(@audiobook)
    assert_equal [ "listen", "audiobook", "Audiobook", "Start listening", "/read/#{@audiobook.id}" ],
      audiobook.values_at("action", "book_type", "format_label", "progress_label", "reader_url")
    assert_not_includes response.body, "content_url"
    assert_not_includes response.body, @root
  end

  def helper_cover_style(book)
    ApplicationController.helpers.consumer_cover_style(book)
  end

  test "a remote cover is passed through only when it is a plain https address" do
    @ebook.update!(cover_url: "https://covers.example.test/quiet.jpg")
    @audiobook.update!(cover_url: "http://covers.example.test/insecure.jpg")
    assert_equal "https://covers.example.test/quiet.jpg", library_item(@ebook).dig("cover", "url")
    assert_nil library_item(@audiobook).dig("cover", "url")
    @ebook.update!(cover_url: "https://user:secret@covers.example.test/quiet.jpg")
    assert_nil library_item(@ebook).dig("cover", "url")
  end

  test "filters and sorting use the shared catalogue rules" do
    listen_to_audiobook
    preview_get web_preview_api_library_path(type: "audiobook")
    assert_equal [ @audiobook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    preview_get web_preview_api_library_path(status: "in_progress")
    assert_equal [ @audiobook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    preview_get web_preview_api_library_path(status: "unread")
    assert_equal [ @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    preview_get web_preview_api_library_path(q: "reader")
    assert_equal [ @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    preview_get web_preview_api_library_path(sort: "title")
    assert_equal [ @audiobook.id.to_s, @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    preview_get web_preview_api_library_path(q: "no such story")
    assert_equal [], response.parsed_body.fetch("items")
  end

  test "bad filters are refused without data" do
    [ { type: "film" }, { status: "done" }, { sort: "random" }, { cursor: "garbage" }, { q: "x" * 201 }, { "q" => [ "a" ] }, { "type" => [ "ebook" ] } ].each do |query|
      preview_get web_preview_api_library_path(query)
      assert_response :bad_request, query.inspect
      assert_equal "invalid_request", response.parsed_body.fetch("error")
      assert_not response.parsed_body.key?("items")
    end
  end

  test "load more follows the cursor without gaps or repeats for every sort" do
    35.times { |index| Book.create!(title: "Shelf book #{format('%02d', index)}", author: "A. Shelver", book_type: :ebook, file_path: @epub_path) }
    expected = Book.acquired.where(book_type: %w[ebook audiobook]).pluck(:id).map(&:to_s)
    { "recent" => ->(ids) { ids.sort_by { |id| -id.to_i } }, "title" => nil }.each do |sort, ordering|
      ids = []
      cursor = nil
      pages = 0
      loop do
        preview_get web_preview_api_library_path(sort: sort, limit: "12", cursor: cursor)
        assert_response :success
        page = response.parsed_body
        assert_operator page.fetch("items").size, :<=, 12
        ids.concat(page.fetch("items").map { |item| item.fetch("id") })
        pages += 1
        cursor = page.fetch("next_cursor")
        break unless cursor
      end
      assert_equal expected.sort, ids.sort, sort
      assert_equal ids.uniq, ids
      assert_equal ordering.call(ids), ids if ordering
      assert_equal 4, pages
    end
    preview_get web_preview_api_library_path
    assert_equal 30, response.parsed_body.fetch("items").size
    assert response.parsed_body.fetch("next_cursor")
  end

  test "a cursor belongs to its filters and account" do
    10.times { |index| Book.create!(title: "Cursor book #{index}", author: "A. Cursor", book_type: :ebook, file_path: @epub_path) }
    preview_get web_preview_api_library_path(limit: "3")
    cursor = response.parsed_body.fetch("next_cursor")
    preview_get web_preview_api_library_path(limit: "3", cursor: cursor, type: "ebook")
    assert_response :bad_request
    sign_out
    sign_in_as(users(:two))
    preview_get web_preview_api_library_path(limit: "3", cursor: cursor), user: users(:two)
    assert_response :bad_request
  end

  test "continue lists the places this account saved and nobody else's" do
    preview_get web_preview_api_continue_path
    assert_equal [], response.parsed_body.fetch("items")
    listen_to_audiobook
    preview_get web_preview_api_continue_path
    assert_response :success
    items = response.parsed_body.fetch("items")
    assert_equal [ @audiobook.id.to_s ], items.map { |item| item.fetch("id") }
    progress = items.sole.fetch("progress")
    saved = users(:one).consumer_progresses.find_by!(book: @audiobook)
    assert_equal({ "asset_id" => consumer_asset(@audiobook).id, "position_seconds" => 17.5, "fraction" => nil, "page" => nil, "version" => 1,
      "observed_at" => saved.observed_at&.utc&.iso8601(3), "updated_at" => saved.updated_at.utc.iso8601(3) }, progress)
    assert_equal "Resume at 0:17", items.sole.fetch("progress_label")
    assert_equal "in_progress", items.sole.fetch("reading_status")
    sign_out
    sign_in_as(users(:two))
    preview_get web_preview_api_continue_path, user: users(:two)
    assert_equal [], response.parsed_body.fetch("items")
    preview_get web_preview_api_library_path, user: users(:two)
    assert_nil response.parsed_body.fetch("items").find { |item| item.fetch("id") == @audiobook.id.to_s }.fetch("progress")
  end

  test "continue honours the type filter" do
    listen_to_audiobook
    preview_get web_preview_api_continue_path(type: "ebook")
    assert_equal [], response.parsed_body.fetch("items")
    preview_get web_preview_api_continue_path(type: "audiobook")
    assert_equal [ @audiobook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
  end

  test "details carry plain text, exact asset identity and the files, and opening them writes nothing" do
    @ebook.update!(description: "<p>First <b>line</b> &amp; more</p><script>alert(1)</script><p>Second\nline</p>")
    assert_no_difference [ "ConsumerProgress.count", "ConsumerReadingState.count", "APIToken.count" ] do
      preview_get "#{web_preview_api_library_path}/#{@ebook.id}"
    end
    assert_response :success
    publication = response.parsed_body.fetch("publication")
    assert_equal users(:one).id.to_s, response.parsed_body.fetch("account")
    assert_equal "First line & more\n\nSecond\nline", publication.fetch("description")
    asset = Consumer::LibraryAssets.new(@ebook, formats: Consumer::ReaderFormats::SUPPORTED).list.sole
    assert_equal [ { "id" => asset.id, "filename" => "A Book.epub", "format" => "epub", "media_type" => "application/epub+zip",
      "size_bytes" => File.size(@epub_path), "position" => 0, "page_count" => nil } ], publication.fetch("files")
    assert_nil publication.fetch("book_page")
    assert_equal library_item(@ebook), publication.except("description", "files", "book_page")
  end

  test "a book that is gone, unacquired or not a number is not found" do
    unacquired = Book.create!(title: "Wanted only", author: "Nobody", book_type: :ebook)
    [ unacquired.id, 0, 999_999_999, "abc" ].each do |id|
      preview_get "#{web_preview_api_library_path}/#{id}"
      assert_response :not_found, id.to_s
      assert_equal({ "error" => "not_found" }, response.parsed_body)
    end
    @ebook.destroy!
    preview_get "#{web_preview_api_library_path}/#{@ebook.id}"
    assert_response :not_found
  end

  test "a book whose files disappeared is shown as unavailable" do
    File.delete(@epub_path)
    item = library_item(@ebook)
    assert_equal [ "unavailable", "Files unavailable" ], item.values_at("availability", "progress_label")
    preview_get "#{web_preview_api_library_path}/#{@ebook.id}"
    assert_equal [], response.parsed_body.dig("publication", "files")
  end

  test "reading status uses the shared semantics, keeps the saved place and returns the details" do
    listen_to_audiobook
    saved = users(:one).consumer_progresses.find_by!(book: @audiobook).attributes
    with_forgery_protection do
      token = csrf_token
      put "#{web_preview_api_library_path}/#{@audiobook.id}/reading_status", params: { status: "finished" }, headers: account_headers(users(:one)).merge("X-CSRF-Token" => token), as: :json
    end
    assert_response :success
    publication = response.parsed_body.fetch("publication")
    assert_equal [ "finished", "Finished" ], publication.values_at("reading_status", "progress_label")
    assert_equal 17.5, publication.dig("progress", "position_seconds")
    assert_equal "finished", users(:one).consumer_reading_states.find_by!(book: @audiobook).status
    assert_equal saved, users(:one).consumer_progresses.find_by!(book: @audiobook).attributes
    assert_equal "unread", ConsumerReadingState.statuses.key(0)
    assert_equal 0, users(:two).consumer_reading_states.count
  end

  test "reading status refuses bad values and a missing or wrong CSRF token without writing" do
    with_forgery_protection do
      token = csrf_token
      headers = account_headers(users(:one)).merge("X-CSRF-Token" => token)
      [ "", "done", nil ].each do |status|
        put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: status }, headers: headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "invalid_reading_status", response.parsed_body.fetch("error")
      end
      put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: [ "finished" ] }, headers: headers, as: :json
      assert_response :unprocessable_entity
      [ account_headers(users(:one)), account_headers(users(:one)).merge("X-CSRF-Token" => "forged") ].each do |without|
        put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: without, as: :json
        assert_response :unprocessable_entity
        assert_equal({ "error" => "invalid_csrf" }, response.parsed_body)
      end
    end
    assert_equal 0, ConsumerReadingState.count
  end

  test "reading status on a missing book is not found" do
    with_forgery_protection do
      token = csrf_token
      put "#{web_preview_api_library_path}/999999/reading_status", params: { status: "finished" }, headers: account_headers(users(:one)).merge("X-CSRF-Token" => token), as: :json
    end
    assert_response :not_found
    assert_equal 0, ConsumerReadingState.count
  end

  test "the session names the account, the server, the classic pages and the account's unread notifications, and reveals admin only to admins" do
    Notification.create!(user: users(:one), title: "Ready", message: "Your book arrived", notification_type: "request_completed")
    preview_get web_preview_api_session_path
    assert_response :success
    assert_equal({ "account" => { "id" => users(:one).id.to_s, "name" => "User One" },
      "server" => { "name" => "www.example.com", "version" => Consumer::ServerInfo.server_version },
      "links" => { "legacy_library" => "/read", "discover" => "/search", "requests" => "/requests", "account" => "/profile" },
      "notifications" => { "url" => "/notifications", "unread" => users(:one).notifications.unread.count },
      "capabilities" => { "administrator" => false, "can_upload" => false, "single_sign_on" => false, "hardcover_personal_access" => false } }, response.parsed_body)
    assert_operator users(:one).notifications.unread.count, :>, 0
    sign_out
    sign_in_as(users(:two))
    preview_get web_preview_api_session_path, user: users(:two)
    assert_equal({ "url" => "/admin" }, response.parsed_body.fetch("admin"))
    assert_equal({ "administrator" => true, "can_upload" => true }, response.parsed_body.fetch("capabilities").slice("administrator", "can_upload"))
    assert_equal users(:two).id.to_s, response.parsed_body.dig("account", "id")
  end
end
