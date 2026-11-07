# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

class API::Consumer::V1::LibraryControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  test "personal consumer tokens browse acquired local publications without filesystem paths or global credentials" do
    pending = Book.create!(title: "Still requested", book_type: :ebook)
    get "/api/consumer/v1/library", headers: @headers
    assert_response :success
    items = response.parsed_body.fetch("items")
    assert_includes items.map { |item| item.fetch("id") }, @ebook.id.to_s
    assert_not_includes items.map { |item| item.fetch("id") }, pending.id.to_s
    assert_not_includes response.body, @root
    publication = items.find { |item| item.fetch("id") == @ebook.id.to_s }
    assert_equal "epub", publication.fetch("assets").sole.fetch("format")
    assert_nil publication.fetch("progress")
    assert_includes response.headers["Cache-Control"], "no-store"
    SettingsService.set(:api_token, "legacy-global-token")
    get "/api/consumer/v1/library", headers: { "Authorization" => "Bearer legacy-global-token" }
    assert_response :unauthorized
    sign_in_as(users(:one))
    get "/api/consumer/v1/library"
    assert_response :unauthorized
  end

  test "wrong scopes deleted users expired and revoked tokens cannot fetch media" do
    _, raw = APIToken.issue!(name: "Search only", user: users(:one), scopes: [ "search:read" ])
    get "/api/consumer/v1/library", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
    @token.update!(expires_at: 1.second.ago)
    get "/api/consumer/v1/library", headers: @headers
    assert_response :unauthorized
    @token.update!(expires_at: nil)
    users(:one).update!(deleted_at: Time.current)
    get "/api/consumer/v1/library", headers: @headers
    assert_response :unauthorized
  end

  test "native identity and disconnect use only the current account and credential" do
    get "/api/consumer/v1/me", headers: @headers
    assert_response :success
    assert_equal users(:one).username, response.parsed_body.fetch("username")
    post "/api/consumer/v1/auth/revoke", headers: @headers
    assert_response :no_content
    assert @token.reload.revoked?
    get "/api/consumer/v1/me", headers: @headers
    assert_response :unauthorized
  end

  test "bounded keyset pages honor search filters and bind cursors to their user and query" do
    get "/api/consumer/v1/library", params: { limit: 1 }, headers: @headers
    assert_response :success
    page_one = response.parsed_body
    assert_equal 1, page_one.fetch("items").size
    get "/api/consumer/v1/library", params: { limit: 1, cursor: page_one.fetch("next_cursor") }, headers: @headers
    assert_response :success
    assert_not_equal page_one.fetch("items").sole.fetch("id"), response.parsed_body.fetch("items").sole.fetch("id")
    get "/api/consumer/v1/library", params: { cursor: page_one.fetch("next_cursor"), type: "ebook" }, headers: @headers
    assert_response :bad_request
    get "/api/consumer/v1/library", params: { type: "ebook", q: "Quiet" }, headers: @headers
    assert_equal [ @ebook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    get "/api/consumer/v1/library", params: { type: "comicbook" }, headers: @headers
    assert_response :bad_request
    get "/api/consumer/v1/library", params: { q: { bad: "data" } }, headers: @headers
    assert_response :bad_request
  end

  test "full HEAD and ranged media use edition-specific validated bytes" do
    asset = consumer_asset(@audiobook)
    url = "/api/consumer/v1/library/#{@audiobook.id}/assets/#{asset.id}"
    original = File.binread(@audio_path)
    get url, headers: @headers
    assert_response :success
    assert_equal original, response.body
    assert_equal "audio/mpeg", response.media_type
    etag = response.headers.fetch("ETag")
    get url, headers: @headers.merge("If-None-Match" => etag)
    assert_response :not_modified
    assert_equal "", response.body
    head url, headers: @headers.merge("Range" => "bytes=0-4")
    assert_response :ok
    assert_equal original.size.to_s, response.headers["Content-Length"]
    assert_equal "", response.body
    { "bytes=0-4" => original.byteslice(0, 5), "bytes=7-" => original.byteslice(7..), "bytes=-5" => original.byteslice(-5, 5) }.each do |range, bytes|
      get url, headers: @headers.merge("Range" => range, "If-Range" => etag)
      assert_response :partial_content
      assert_equal bytes, response.body
      assert_equal bytes.size.to_s, response.headers["Content-Length"]
    end
    get url, headers: @headers.merge("Range" => "bytes=0-4", "If-Range" => '"old-edition"')
    assert_response :ok
    assert_equal original, response.body
    %w[bytes=900- bytes=5-2 bytes=-0 bytes=0-1,4-5 nope].each do |range|
      get url, headers: @headers.merge("Range" => range)
      assert_response :range_not_satisfiable
      assert_equal "bytes */#{original.size}", response.headers["Content-Range"]
    end
    File.rename(@audio_path, "#{@audio_path}.old")
    File.write(@audio_path, "a different media edition")
    get url, headers: @headers
    assert_response :gone
    assert_not_includes response.body, @root
  end

  test "unsafe missing ambiguous-root and unsupported publications never expose library bytes" do
    @ebook.update!(file_path: "/etc/passwd")
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    assert_response :success
    assert_empty response.parsed_body.fetch("assets")
    @ebook.update!(file_path: @root)
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    assert_empty response.parsed_body.fetch("assets")
    get "/api/consumer/v1/library/#{@ebook.id}x", headers: @headers
    assert_response :not_found
    @ebook.update!(file_path: nil)
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    assert_response :not_found
  end
end
