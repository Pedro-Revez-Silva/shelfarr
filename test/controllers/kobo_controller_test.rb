# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboControllerTest < ActionDispatch::IntegrationTest
  include KoboTestHelper

  setup do
    prepare_kobo_book
    @delivery = @device.send_book!(@book)
    @base = "/kobo/#{@token}"
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "stock firmware authenticates without a cookie or modern browser and receives trusted base URLs" do
    get "#{@base}/v1/initialization", headers: { "User-Agent" => "Mozilla/5.0 (Kobo Touch; Linux) AppleWebKit/538.1", "Host" => "wrong.example:80:80" }
    assert_response :success
    assert_equal "e30=", response.headers["x-kobo-apitoken"]
    assert_equal "https://shelfarr.example#{@base}/v1/library/sync", response.parsed_body.fetch("Resources").fetch("library_sync")
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "all protocol routes require an active reader capability" do
    %w[v1/initialization v1/library/sync v1/library/tags].each do |path|
      get "/kobo/#{'0' * 64}/#{path}"
      assert_response :unauthorized
    end
    @device.user.update!(deleted_at: Time.current)
    get "#{@base}/v1/library/sync"
    assert_response :unauthorized
  end

  test "refresh returns protocol credentials without using them to authorize other readers" do
    post "#{@base}/v1/auth/device", params: { UserKey: "device-account" }, as: :json
    assert_response :success
    assert_equal "device-account", response.parsed_body.fetch("UserKey")
    access = response.parsed_body.fetch("AccessToken")
    post "#{@base}/v1/auth/refresh", params: {}, as: :json
    assert_response :success
    assert_not_equal access, response.parsed_body.fetch("AccessToken")
    get "/kobo/#{'0' * 64}/v1/library/sync", headers: { "Authorization" => "Bearer #{access}" }
    assert_response :unauthorized
  end

  test "sync is repeatable and incremental without resetting reading progress" do
    get "#{@base}/v1/library/sync"
    assert_response :success
    item = response.parsed_body.sole.fetch("NewEntitlement")
    assert_equal @delivery.entitlement_id, item.fetch("BookEntitlement").fetch("Id")
    assert_not item.key?("ReadingState")
    urls = item.fetch("BookMetadata").fetch("DownloadUrls")
    assert_equal %w[EPUB3 EPUB], urls.map { |url| url.fetch("Format") }
    assert_equal File.size(@path), urls.first.fetch("Size")
    cursor = response.headers.fetch("x-kobo-synctoken")
    assert_not_nil @device.reload.last_sync_at

    get "#{@base}/v1/library/sync", headers: { "x-kobo-synctoken" => cursor }
    assert_equal [], response.parsed_body
    @device.send_book!(@book)
    get "#{@base}/v1/library/sync", headers: { "x-kobo-synctoken" => cursor }
    assert_equal @delivery.entitlement_id, response.parsed_body.sole.fetch("NewEntitlement").fetch("BookEntitlement").fetch("Id")
    get "#{@base}/v1/library/sync"
    assert_equal @delivery.entitlement_id, response.parsed_body.sole.fetch("NewEntitlement").fetch("BookEntitlement").fetch("Id")
  end

  test "another reader cannot see or download this selection and token revocation takes effect" do
    other, token = KoboDevice.issue(user: users(:one), name: "Older Kobo", base_url: @device.base_url)
    other.save!
    get "/kobo/#{token}/v1/library/sync"
    assert_equal [], response.parsed_body
    get "/kobo/#{token}/v1/library/#{@delivery.entitlement_id}/metadata"
    assert_response :not_found
    get "/kobo/#{token}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    assert_response :not_found
    @device.rotate_token!
    get "#{@base}/v1/library/sync"
    assert_response :unauthorized
  end

  test "metadata and embedded covers are restricted to selected books" do
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/metadata"
    assert_response :success
    assert_equal @book.title, response.parsed_body.sole.fetch("Title")
    get "#{@base}/#{@delivery.entitlement_id}/600/800/false/image.jpg"
    assert_response :success
    assert_equal "image/png", response.media_type
    assert response.body.start_with?("\x89PNG".b)
    get "#{@base}/#{@delivery.entitlement_id}/600/800/90/true/image.jpg"
    assert_response :success
    get "#{@base}/v1/library/tags"
    assert_equal({ "Tags" => [] }, response.parsed_body)
  end

  test "full and resumed downloads return bytes from the same pinned edition" do
    url = "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    original = File.binread(@path)
    get url
    assert_response :ok
    assert_equal original, response.body.b
    assert_equal "bytes", response.headers["Accept-Ranges"]
    etag = response.headers["ETag"]
    assert_not_nil @delivery.reload.last_download_at
    { "bytes=0-9" => original.byteslice(0, 10), "bytes=10-" => original.byteslice(10..),
      "bytes=-12" => original.byteslice(-12, 12), "bytes=0-999999" => original }.each do |range, expected|
      get url, headers: { "Range" => range, "If-Range" => etag }
      assert_response :partial_content
      assert_equal expected, response.body.b
      assert_equal expected.bytesize.to_s, response.headers["Content-Length"]
      assert_match(/\Abytes \d+-\d+\/#{original.bytesize}\z/, response.headers["Content-Range"])
    end
    get url, headers: { "Range" => "bytes=0-9", "If-Range" => '"previous-edition"' }
    assert_response :ok
    assert_equal original, response.body.b
    head url, headers: { "Range" => "bytes=0-9" }
    assert_response :ok
    assert_equal "", response.body
    assert_equal original.bytesize.to_s, response.headers["Content-Length"]
  end

  test "unsatisfiable malformed and multiple ranges never stream source bytes" do
    %w[bytes=999999- bytes=10-2 bytes=-0 bytes=- bytes=0-1,4-5 junk].each do |range|
      get "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}", headers: { "Range" => range }
      assert_response :range_not_satisfiable
      assert_equal "bytes */#{File.size(@path)}", response.headers["Content-Range"]
      assert_equal "", response.body
    end
  end

  test "file replacement and removal do not serve unrelated bytes or remove a reader copy" do
    old_url = "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    File.rename(@path, "#{@path}.old")
    write_epub(@path, version: "2.0")
    get old_url
    assert_response :gone
    @device.send_book!(@book)
    get old_url
    assert_response :not_found
    @book.destroy!
    assert_nil @delivery.reload.book_id
    get "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    assert_response :gone
    get "#{@base}/v1/library/sync"
    assert_equal false, response.parsed_body.sole.fetch("NewEntitlement").fetch("BookEntitlement").fetch("IsRemoved")
  end

  test "reader state is retained for this reader without putting it on another reader" do
    body = { ReadingStates: [ { EntitlementId: @delivery.entitlement_id, CurrentBookmark: { ProgressPercent: 37, Location: { Value: "chapter3" } }, StatusInfo: { Status: "Reading" } } ] }
    put "#{@base}/v1/library/#{@delivery.entitlement_id}/state", params: body, as: :json
    assert_response :success
    assert_equal "Success", response.parsed_body.fetch("RequestResult")
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_equal 37, response.parsed_body.sole.fetch("CurrentBookmark").fetch("ProgressPercent")
    assert_equal 1, @device.reload.sync_revision
    get "#{@base}/v1/library/sync"
    assert_equal "chapter3", response.parsed_body.sole.fetch("NewEntitlement").fetch("ReadingState").fetch("CurrentBookmark").fetch("Location").fetch("Value")
    @device.send_book!(@book)
    assert_equal 37, @delivery.reload.reading_state.fetch("CurrentBookmark").fetch("ProgressPercent")
    write_epub(@path, version: "2.0")
    @device.send_book!(@book)
    assert_nil @delivery.reload.reading_state
  end

  test "malformed and oversized protocol bodies are rejected" do
    url = "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    [ {}, { ReadingStates: [] }, { ReadingStates: [ { EntitlementId: "other" } ] },
      { ReadingStates: [ { EntitlementId: @delivery.entitlement_id, Statistics: "invalid" } ] } ].each do |body|
      put url, params: body, as: :json
      assert_response :bad_request
    end
    post "#{@base}/v1/auth/device", params: [].to_json, headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    post "#{@base}/v1/auth/device", params: { UserKey: "x" * 65_536 }, as: :json
    assert_response :content_too_large
    assert_nil @delivery.reload.reading_state
  end

  test "Rails logging redacts path capabilities and account keys" do
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    post "#{@base}/v1/auth/device", params: { UserKey: "private-kobo-account" }, as: :json
    assert_response :success
    assert_includes output.string, "/kobo/[FILTERED]/v1/auth/device"
    assert_not_includes output.string, @token
    assert_not_includes output.string, "private-kobo-account"
    output.truncate(0)
    output.rewind
    get "#{@base}/v1/unknown-firmware-endpoint"
    assert_response :not_found
    get @base
    assert_response :not_found
    assert_not_includes output.string, @token
  ensure
    Rails.logger = previous_logger
  end
end
