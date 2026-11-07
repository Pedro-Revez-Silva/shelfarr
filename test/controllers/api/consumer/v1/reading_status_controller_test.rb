# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

class API::Consumer::V1::ReadingStatusControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  test "status is personal and explicit choices keep saved places despite later progress writes" do
    put "/api/consumer/v1/library/#{@audiobook.id}/progress", params: audio_progress, headers: @headers, as: :json
    assert_response :success
    original = response.parsed_body.fetch("progress")
    put "/api/consumer/v1/library/#{@audiobook.id}/reading_status", params: { status: "finished" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "finished", response.parsed_body.fetch("reading_status")
    assert_equal original, response.parsed_body.fetch("progress")
    put "/api/consumer/v1/library/#{@audiobook.id}/progress", params: audio_progress(version: 1, seconds: 20), headers: @headers, as: :json
    assert_response :success
    get "/api/consumer/v1/library/#{@audiobook.id}", headers: @headers
    assert_equal "finished", response.parsed_body.fetch("reading_status")
    _, other = APIToken.issue!(name: "Other reader", user: users(:two), scopes: ConsumerDeviceGrant::SCOPES)
    get "/api/consumer/v1/library/#{@audiobook.id}", headers: { "Authorization" => "Bearer #{other}" }
    assert_equal "unread", response.parsed_body.fetch("reading_status")
    assert_nil response.parsed_body.fetch("progress")
    put "/api/consumer/v1/library/#{@audiobook.id}/reading_status", params: { status: "unread" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "unread", response.parsed_body.fetch("reading_status")
    assert_equal 20, response.parsed_body.dig("progress", "position_seconds")
  end

  test "status validates values scopes and acquired publications" do
    [ "unknown", [ "finished" ], nil ].each do |status|
      put "/api/consumer/v1/library/#{@ebook.id}/reading_status", params: { status: status }, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
    assert_empty users(:one).consumer_reading_states
    _, read_only = APIToken.issue!(name: "Read only", user: users(:one), scopes: [ "library:read" ])
    put "/api/consumer/v1/library/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: { "Authorization" => "Bearer #{read_only}" }, as: :json
    assert_response :forbidden
    pending = Book.create!(title: "Not acquired", book_type: :ebook)
    put "/api/consumer/v1/library/#{pending.id}/reading_status", params: { status: "finished" }, headers: @headers, as: :json
    assert_response :not_found
  end

  test "continue spans the library respects manual status and excludes unavailable or replaced editions" do
    asset = consumer_asset(@ebook)
    user = users(:one)
    user.consumer_progresses.create!(book: @ebook, asset_id: asset.id, locator: { "href" => "OEBPS/chapter.xhtml", "locations" => { "progression" => 0.2 } }, version: 1, client_mutation_id: SecureRandom.uuid)
    35.times { |n| Book.create!(title: "Newer #{n}", book_type: :ebook, file_path: @epub_path) }
    get "/api/consumer/v1/library", headers: @headers
    assert_not_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @ebook.id.to_s
    get "/api/consumer/v1/continue", headers: @headers
    assert_response :success
    assert_equal [ @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    put "/api/consumer/v1/library/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: @headers, as: :json
    get "/api/consumer/v1/continue", headers: @headers
    assert_empty response.parsed_body.fetch("items")
    put "/api/consumer/v1/library/#{@ebook.id}/reading_status", params: { status: "in_progress" }, headers: @headers, as: :json
    File.binwrite(@epub_path, "replacement content")
    get "/api/consumer/v1/continue", headers: @headers
    assert_empty response.parsed_body.fetch("items")
    File.unlink(@epub_path)
    get "/api/consumer/v1/continue", headers: @headers
    assert_empty response.parsed_body.fetch("items")
  end

  test "title pages handle duplicate titles unicode and cursor binding to sort status and account" do
    %w[Alpha alpha Beta Éclair éclair].each { |title| Book.create!(title: title, book_type: :ebook, file_path: @epub_path) }
    seen = []
    cursor = nil
    first_cursor = nil
    loop do
      get "/api/consumer/v1/library", params: { sort: "title", type: "ebook", limit: "2", cursor: cursor }, headers: @headers
      assert_response :success
      data = response.parsed_body
      seen.concat(data.fetch("items").map { |item| item.fetch("id") })
      cursor = data.fetch("next_cursor")
      first_cursor ||= cursor
      break unless cursor
    end
    assert_equal 6, seen.size
    assert_equal seen.uniq, seen
    [ { sort: "recent" }, { sort: "title", status: "unread" } ].each do |options|
      get "/api/consumer/v1/library", params: options.merge(cursor: first_cursor, type: "ebook"), headers: @headers
      assert_response :bad_request
    end
    put "/api/consumer/v1/library/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: @headers, as: :json
    get "/api/consumer/v1/library", params: { status: "finished" }, headers: @headers
    assert_equal [ @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    get "/api/consumer/v1/library", params: { status: "not-a-state" }, headers: @headers
    assert_response :bad_request
    get "/api/consumer/v1/library", params: { sort: "unsupported" }, headers: @headers
    assert_response :bad_request
  end
end
