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

  test "a plain EPUB downloads as its prepared Kobo edition, resumes, and stops after the library file is replaced" do
    prepare_plain_epub
    original = File.binread(@path)
    delivery = @device.send_book!(@book)
    copy = File.binread(Kobo::KepubCache.root.join(delivery.kobo_kepub_copy.storage_key))
    url = "#{@base}/download/#{delivery.entitlement_id}/#{delivery.revision_id}"
    get url
    assert_response :ok
    assert_equal copy, response.body.b
    assert_not_equal original, copy
    assert_match(/filename="Book\.kepub\.epub"/, response.headers["Content-Disposition"])
    get url, headers: { "Range" => "bytes=10-", "If-Range" => response.headers["ETag"] }
    assert_response :partial_content
    assert_equal copy.byteslice(10..), response.body.b
    assert_equal original, File.binread(@path), "serving the copy never touches the library file"

    get "#{@base}/v1/library/#{delivery.entitlement_id}/metadata"
    assert_equal [ "KEPUB" ], response.parsed_body.sole.fetch("DownloadUrls").map { |entry| entry["Format"] }

    File.open(Kobo::KepubCache.root.join(".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      File.unlink(Kobo::KepubCache.root.join(delivery.kobo_kepub_copy.storage_key))
      Kobo::KepubCache.lock_wait = 0.1
      get url
      assert_response :service_unavailable, "a lost copy being rebuilt elsewhere is not gone"
    ensure
      Kobo::KepubCache.lock_wait = nil
    end
    get url
    assert_response :ok
    assert_equal copy, response.body.b, "the lost copy was rebuilt byte for byte"

    prepare_plain_epub(chapters: { "OEBPS/Text/ch2.xhtml" => plain_chapter(2, paragraphs: 7) })
    get url
    assert_response :gone, "a replaced source never serves its earlier copy"
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
    head "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_response :success
    assert_nil @delivery.reload.reading_state
    body = { ReadingStates: [ { EntitlementId: @delivery.entitlement_id, CurrentBookmark: { ProgressPercent: 37, Location: { Value: "chapter3" } }, StatusInfo: { Status: "Reading" } } ] }
    put "#{@base}/v1/library/#{@delivery.entitlement_id}/state", params: body, as: :json
    assert_response :success
    assert_equal "Success", response.parsed_body.fetch("RequestResult")
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_equal 37, response.parsed_body.sole.fetch("CurrentBookmark").fetch("ProgressPercent")
    assert_no_changes -> { @delivery.reload.reading_state } do
      head "#{@base}/v1/library/#{@delivery.entitlement_id}/state", params: { ReadingStates: [ { CurrentBookmark: { ProgressPercent: 99 } } ] }, as: :json
      assert_response :success
    end
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

  STORE = "https://storeapi.kobo.com"

  def coexist!
    @device.update!(store_coexistence: true)
  end

  def kobo_headers
    { "Authorization" => "Bearer reader-own-kobo", "X-Kobo-Deviceid" => "reader-device" }
  end

  test "coexistence keeps Kobo's resources and sign-in while Shelfarr answers library sync under its subpath" do
    @device.update!(store_coexistence: true, base_url: "https://shelfarr.example/books")
    stub_request(:get, "#{STORE}/v1/initialization").with(headers: { "Authorization" => "Bearer reader-own-kobo" })
      .to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Apitoken" => "store-api" }, body: { Resources: {
        "library_sync" => "#{STORE}/v1/library/sync", "device_auth" => "#{STORE}/v1/auth/device",
        "user_profile" => "#{STORE}/v1/user/profile", "image_url_template" => "https://cdn.kobo.com/book-images/{ImageId}/{Width}/{Height}/false/image.jpg" } }.to_json)
    get "#{@base}/v1/initialization", headers: kobo_headers, env: { "SCRIPT_NAME" => "/books" }
    assert_response :success
    resources = response.parsed_body.fetch("Resources")
    assert_equal "https://shelfarr.example/books#{@base}/v1/library/sync", resources.fetch("library_sync")
    assert_equal "https://shelfarr.example/books#{@base}/v1/library/{Ids}/state", resources.fetch("reading_state")
    assert_equal "https://shelfarr.example/books#{@base}/{ImageId}/{Width}/{Height}/false/image.jpg", resources.fetch("image_url_template")
    assert_equal "#{STORE}/v1/auth/device", resources.fetch("device_auth"), "the reader signs in with Kobo directly"
    assert_equal "#{STORE}/v1/user/profile", resources.fetch("user_profile")
    assert_equal "store-api", response.headers["x-kobo-apitoken"]
  end

  test "coexistence initialization falls back to Shelfarr's relay without placeholder sign-in when the Store is down" do
    coexist!
    [ { status: 503 }, { body: "{}" }, { body: "[]" }, { body: "not json" } ].each do |answer|
      stub_request(:get, "#{STORE}/v1/initialization").to_return(**answer)
      get "#{@base}/v1/initialization", headers: kobo_headers
      assert_response :success
      assert_equal "https://shelfarr.example#{@base}/v1/auth/device", response.parsed_body.dig("Resources", "device_auth")
      assert_equal "unavailable", @device.reload.store_status
    end
    stub_request(:post, "#{STORE}/v1/auth/device").to_timeout
    post "#{@base}/v1/auth/device", params: { UserKey: "account" }, as: :json, headers: kobo_headers
    assert_response :service_unavailable
    assert_not response.body.include?("AccessToken")
    assert_nil @device.reload.placeholder_auth_at

    stub_request(:get, "#{STORE}/v1/initialization").to_return(status: 401, headers: { "WWW-Authenticate" => "Bearer" })
    get "#{@base}/v1/initialization", headers: kobo_headers
    assert_response :unauthorized
    stub_request(:get, "#{STORE}/v1/initialization").to_return(status: 400, body: { ResponseStatus: {} }.to_json, headers: { "Content-Type" => "application/json" })
    get "#{@base}/v1/initialization", headers: kobo_headers
    assert_response :bad_request
    assert_equal({ "ResponseStatus" => {} }, response.parsed_body)
  end

  test "coexistence relays the reader's own sign-in, and only Shelfarr-only mode issues placeholders" do
    coexist!
    stub_request(:post, "#{STORE}/v1/auth/refresh").with(body: { RefreshToken: "reader-refresh" }.to_json)
      .to_return(headers: { "Content-Type" => "application/json" }, body: { AccessToken: "kobo-issued", TokenType: "Bearer" }.to_json)
    post "#{@base}/v1/auth/refresh", params: { RefreshToken: "reader-refresh" }.to_json, headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_response :success
    assert_equal "kobo-issued", response.parsed_body.fetch("AccessToken")
    assert_nil @device.reload.placeholder_auth_at

    @device.update!(store_coexistence: false)
    post "#{@base}/v1/auth/device", params: { UserKey: "account" }, as: :json
    assert_response :success
    assert_not_nil @device.reload.placeholder_auth_at
  end

  test "coexistence sync merges Shelfarr books with the reader's Store library and keeps Kobo's cursor private" do
    coexist!
    stub_request(:get, "#{STORE}/v1/library/sync").with { |request|
      request.headers["Authorization"] == "Bearer reader-own-kobo" && request.headers["X-Kobo-Synctoken"].nil?
    }.to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Synctoken" => "store-next" },
      body: [ { "NewEntitlement" => { "BookEntitlement" => { "Id" => "store-book" } } } ].to_json)
    get "#{@base}/v1/library/sync", headers: kobo_headers.merge("X-Kobo-Synctoken" => "reader-store-cursor")
    assert_response :success
    assert_equal [ @delivery.entitlement_id, "store-book" ], response.parsed_body.map { |item| item.values.first.dig("BookEntitlement", "Id") }
    combined = response.headers.fetch("x-kobo-synctoken")
    assert combined.start_with?("sf2.")
    assert_not_includes combined, "store-next"

    stub_request(:get, "#{STORE}/v1/library/sync").with(headers: { "X-Kobo-Synctoken" => "store-next" }).to_return(status: 500)
    get "#{@base}/v1/library/sync", headers: kobo_headers.merge("X-Kobo-Synctoken" => combined)
    assert_response :success
    assert_equal [], response.parsed_body
    assert_equal "store-next", Kobo::SyncCursor.new(@device, authorization: kobo_headers.fetch("Authorization")).read(response.headers["x-kobo-synctoken"]).store

    # Switching back to Shelfarr-only keeps the local position: no replay.
    @device.update!(store_coexistence: false)
    get "#{@base}/v1/library/sync", headers: { "X-Kobo-Synctoken" => combined }
    assert_equal [], response.parsed_body
    assert_not_requested :get, "#{STORE}/v1/library/sync", headers: { "X-Kobo-Synctoken" => combined }
  end

  test "Store book metadata, state, covers and other requests go to Kobo while Shelfarr books stay local" do
    coexist!
    stub_request(:get, "#{STORE}/v1/library/store-book/metadata").to_return(headers: { "Content-Type" => "application/json" }, body: [ { Title: "Store" } ].to_json)
    get "#{@base}/v1/library/store-book/metadata", headers: kobo_headers
    assert_equal [ "Store" ], response.parsed_body.map { |item| item["Title"] }
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/metadata", headers: kobo_headers
    assert_equal @book.title, response.parsed_body.sole.fetch("Title")
    get "#{@base}/v1/library/store-book,#{@delivery.entitlement_id}/metadata", headers: kobo_headers
    assert_equal [ "Store", @book.title ], response.parsed_body.map { |item| item["Title"] }

    state = { ReadingStates: [ { EntitlementId: "store-book", CurrentBookmark: { ProgressPercent: 5 } } ] }.to_json
    stub = stub_request(:put, "#{STORE}/v1/library/store-book/state").with(body: state)
      .to_return(headers: { "Content-Type" => "application/json" }, body: { RequestResult: "Success" }.to_json)
    put "#{@base}/v1/library/store-book/state", params: state, headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_requested stub
    assert_equal "Success", response.parsed_body.fetch("RequestResult")
    put "#{@base}/v1/library/#{@delivery.entitlement_id}/state", params: { ReadingStates: [ { CurrentBookmark: { ProgressPercent: 9 } } ] }.to_json,
      headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_equal 9, @delivery.reload.reading_state.dig("CurrentBookmark", "ProgressPercent")
    assert_not_requested :put, "#{STORE}/v1/library/#{@delivery.entitlement_id}/state"

    get "#{@base}/0c5b1e4e-1111-4b8a-9d6c-000000000001/150/200/false/image.jpg"
    assert_redirected_to "https://cdn.kobo.com/book-images/0c5b1e4e-1111-4b8a-9d6c-000000000001/150/200/false/image.jpg"
    get "#{@base}/0c5b1e4e-1111-4b8a-9d6c-000000000001/150/200/60/true/image.jpg"
    assert_redirected_to "https://cdn.kobo.com/book-images/0c5b1e4e-1111-4b8a-9d6c-000000000001/150/200/60/true/image.jpg"
    get "#{@base}/#{@delivery.entitlement_id}/600/800/false/image.jpg"
    assert_response :success

    stub = stub_request(:post, "#{STORE}/v1/analytics/event?x=1").to_return(status: 204)
    post "#{@base}/v1/analytics/event?x=1", params: "{}", headers: kobo_headers.merge("Content-Type" => "application/json"), env: { "SCRIPT_NAME" => "/books" }
    assert_response :no_content
    assert_requested stub
    assert_equal "default-src 'none'; sandbox", response.headers["Content-Security-Policy"]
    get "#{@base}/v1/library/%2e%2e%2fadmin/x"
    assert_response :not_found
  end

  test "Shelfarr-only readers never contact the Store" do
    get "#{@base}/0c5b1e4e-1111-4b8a-9d6c-000000000001/150/200/false/image.jpg"
    assert_response :not_found
    get "#{@base}/v1/user/profile", headers: kobo_headers
    assert_response :success
    assert_equal({}, response.parsed_body)
    get "#{@base}/v1/library/store-book/metadata"
    assert_response :not_found
    assert_not_requested :any, /kobo\.com/
  end

  test "relayed Store requests log neither the reader's Kobo sign-in nor its identifiers" do
    coexist!
    output = StringIO.new
    previous_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    stub_request(:post, "#{STORE}/v1/analytics/event").to_return(status: 500, body: "provider-private-detail")
    post "#{@base}/v1/analytics/event", params: { DeviceId: "private-device-id", SerialNumber: "private-serial" }.to_json,
      headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_response :internal_server_error
    assert_includes output.string, "Processing by KoboController#optional_store_resource", "the controller log is captured"
    [ @token, "reader-own-kobo", "private-device-id", "private-serial", "provider-private-detail" ].each do |secret|
      assert_not_includes output.string, secret
    end
  ensure
    Rails.logger = previous_logger
    ActionController::Base.logger = previous_controller_logger
  end

  test "a supported Kobo place is shared with Shelfarr progress while the Kobo response stays the same" do
    @device.update!(share_progress: true)
    write_epub(@path, package: '<package version="3.0"><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
      extra: { "OEBPS/c.xhtml" => "<html/>" })
    delivery = @device.send_book!(@book)
    get "#{@base}/download/#{delivery.entitlement_id}/#{delivery.revision_id}"
    assert_response :success
    read_at = 2.hours.ago.utc
    body = { ReadingStates: [ { EntitlementId: delivery.entitlement_id, CurrentBookmark: { LastModified: read_at.iso8601(7),
      ProgressPercent: 30, ContentSourceProgressPercent: 60, Location: { Type: "KoboSpan", Value: "kobo.4.2", Source: "OEBPS/c.xhtml" } } } ] }
    put "#{@base}/v1/library/#{delivery.entitlement_id}/state", params: body, as: :json
    assert_response :success
    assert_equal "Success", response.parsed_body.fetch("RequestResult")
    saved = users(:one).consumer_progresses.find_by!(book: @book)
    assert_equal({ "href" => "OEBPS/c.xhtml", "type" => "application/xhtml+xml", "locations" => { "progression" => 0.6, "totalProgression" => 0.3 } }, saved.locator)
    assert_equal read_at.floor(3), saved.observed_at
    assert_equal "kobo.4.2", delivery.reload.reading_state.dig("CurrentBookmark", "Location", "Value")
  end

  # The Kobo side of the reverse path: a place saved through the consumer API,
  # then the stock protocol requests a reader makes after it.
  def receive_shelfarr_places!
    prepare_kobo_kepub
    @device.update!(share_progress: true, receive_progress: true)
    @delivery = @device.send_book!(@book)
    get "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    assert_response :success
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
  end

  def read_in_shelfarr(href: "OEBPS/Text/ch2.xhtml", progression: 0.5, at: 1.hour.ago)
    current = users(:one).consumer_progresses.find_by(book: @book)
    Consumer::ProgressWriter.new(user: users(:one), book: @book).call("asset_id" => @asset_id, "expected_version" => current&.version || 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => at.utc.iso8601(3),
      "locator" => { "href" => href, "type" => "application/xhtml+xml", "locations" => { "progression" => progression, "totalProgression" => 0.4 } })
  end

  test "an incremental sync and GET state give the Kobo its Shelfarr place, and its echo changes nothing" do
    receive_shelfarr_places!
    get "#{@base}/v1/library/sync"
    cursor = response.headers.fetch("x-kobo-synctoken")
    read_at = 1.hour.ago.utc.floor(3)
    saved = read_in_shelfarr(at: read_at)

    head "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_response :success
    assert_nil @delivery.reload.progress_outbound, "HEAD has no side effects"

    get "#{@base}/v1/library/sync", headers: { "X-Kobo-Synctoken" => cursor }
    assert_response :success
    state = response.parsed_body.sole.fetch("ChangedReadingState").fetch("ReadingState")
    assert_equal({ "Type" => "KoboSpan", "Source" => "OEBPS/Text/ch2.xhtml", "Value" => "kobo.5.2" }, state.dig("CurrentBookmark", "Location"))
    assert_equal read_at.iso8601(3), state.dig("CurrentBookmark", "LastModified")
    cursor = response.headers.fetch("x-kobo-synctoken")

    get "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_equal state, response.parsed_body.sole, "GET state serves the same place"
    get "#{@base}/v1/library/sync", headers: { "X-Kobo-Synctoken" => cursor }
    assert_equal [], response.parsed_body

    put "#{@base}/v1/library/#{@delivery.entitlement_id}/state", as: :json, params: { ReadingStates: [ {
      EntitlementId: @delivery.entitlement_id, CurrentBookmark: state.fetch("CurrentBookmark").merge("LastModified" => Time.current.utc.iso8601(7),
        "Location" => state.dig("CurrentBookmark", "Location").merge("Source" => "#{@delivery.entitlement_id}!OEBPS!Text/ch2.xhtml")) } ] }
    assert_response :success
    assert_equal "Success", response.parsed_body.fetch("RequestResult")
    assert_equal saved.attributes, users(:one).consumer_progresses.find_by!(book: @book).attributes
    assert_equal "echo", @delivery.reload.progress_bridge["status"]
    get "#{@base}/v1/library/sync", headers: { "X-Kobo-Synctoken" => cursor }
    assert_equal [], response.parsed_body, "an echo never requeues itself"
  end

  test "coexistence adds the Shelfarr place to sync without any reading-state request to the Kobo Store" do
    receive_shelfarr_places!
    coexist!
    stub_request(:get, "#{STORE}/v1/library/sync").to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Synctoken" => "store-next" },
      body: [ { "ChangedReadingState" => { "ReadingState" => { "EntitlementId" => @delivery.entitlement_id, "CurrentBookmark" => {} } } },
        { "ChangedReadingState" => { "ReadingState" => { "EntitlementId" => "store-book", "CurrentBookmark" => {} } } } ].to_json)
    get "#{@base}/v1/library/sync", headers: kobo_headers
    cursor = response.headers.fetch("x-kobo-synctoken")
    read_in_shelfarr
    get "#{@base}/v1/library/sync", headers: kobo_headers.merge("X-Kobo-Synctoken" => cursor)
    assert_response :success
    ids = response.parsed_body.map { |item| item.fetch("ChangedReadingState").dig("ReadingState", "EntitlementId") }
    assert_equal [ @delivery.entitlement_id, "store-book" ], ids, "Kobo's own records never replace Shelfarr's"
    assert_equal "kobo.5.2", response.parsed_body.first.dig("ChangedReadingState", "ReadingState", "CurrentBookmark", "Location", "Value")
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/state", headers: kobo_headers
    assert_response :success
    assert_not_requested :any, %r{\A#{Regexp.escape(STORE)}/v1/library/.*/state}
    assert_not_requested :post, %r{\A#{Regexp.escape(STORE)}/}
    assert_not_requested :put, %r{\A#{Regexp.escape(STORE)}/}
  end

  def tag_items(*revision_ids)
    revision_ids.map { |id| { "RevisionId" => id, "Type" => "ProductRevisionTagItem" } }
  end

  def synced_tags(cursor = nil)
    get "#{@base}/v1/library/sync", headers: cursor ? { "X-Kobo-Synctoken" => cursor } : {}
    assert_response :success
    [ response.parsed_body.select { |item| item.key?("NewTag") || item.key?("ChangedTag") }, response.headers.fetch("x-kobo-synctoken") ]
  end

  test "a Shelfarr-only reader without a Kobo Store account completes every request of its sync" do
    post "#{@base}/v1/auth/device", params: { UserKey: "reader-key" }, as: :json
    assert_response :success
    get "#{@base}/v1/initialization"
    assert_response :success
    %w[v1/affiliate v1/user/profile v1/user/loyalty/benefits v1/deals v1/user/wishlist].each do |path|
      get "#{@base}/#{path}", headers: kobo_headers
      assert_response :success, path
      assert_equal({}, response.parsed_body, path)
    end
    assert_no_changes -> { [ @device.reload.attributes, @delivery.reload.attributes ] } do
      post "#{@base}/v1/analytics/gettests", params: { "Tests" => {} }.to_json, headers: kobo_headers.merge("Content-Type" => "application/json")
      assert_equal({}, response.parsed_body)
      62.times do
        post "#{@base}/v1/analytics/event", params: { Events: [ { EventType: "PageTurn", SerialNumber: "private-serial" } ] }.to_json,
          headers: kobo_headers.merge("Content-Type" => "application/json")
        assert_response :success
        assert_equal({}, response.parsed_body)
      end
    end
    post "#{@base}/v1/library/tags", params: { Name: "Holiday", Items: tag_items(@delivery.revision_id) }, as: :json
    assert_response :created
    tag_id = response.parsed_body
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, tag_id)
    post "#{@base}/v1/library/tags", params: { Name: "Unread", Items: [] }, as: :json
    assert_response :created

    get "#{@base}/v1/library/sync"
    assert_response :success
    assert_equal @delivery.entitlement_id, response.parsed_body.first.fetch("NewEntitlement").fetch("BookEntitlement").fetch("Id")
    tags = response.parsed_body.drop(1).map { |item| item.fetch("NewTag").fetch("Tag") }
    assert_equal [ "Holiday", "Unread" ], tags.map { |tag| tag.fetch("Name") }
    assert_equal({ "Id" => tag_id, "Name" => "Holiday", "Type" => "UserTag", "Items" => tag_items(@delivery.revision_id) },
      tags.first.slice("Id", "Name", "Type", "Items"))
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/metadata"
    assert_response :success
    get "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    assert_response :success
    assert_not_requested :any, /kobo\.com/
  end

  test "collections persist on this reader, survive retries and edits, and come back in a full sync" do
    post "#{@base}/v1/library/tags", params: { Name: "Holiday", Items: tag_items("book-a") }, as: :json
    assert_response :created
    tag_id = response.parsed_body
    _, cursor = synced_tags
    post "#{@base}/v1/library/tags", params: { Name: "Holiday", Items: tag_items("book-a", "book-b") }, as: :json
    assert_response :created
    assert_equal tag_id, response.parsed_body, "a retried create keeps one collection"
    assert_equal 1, @device.kobo_tags.count

    put "#{@base}/v1/library/tags/#{tag_id}", params: { Name: "Summer" }, as: :json
    assert_response :ok
    2.times do
      post "#{@base}/v1/library/tags/#{tag_id}/items", params: { Items: tag_items("book-c") }, as: :json
      assert_response :created
    end
    2.times do
      post "#{@base}/v1/library/tags/#{tag_id}/items/delete", params: { Items: tag_items("book-a") }, as: :json
      assert_response :ok
    end
    changed, cursor = synced_tags(cursor)
    assert_equal({ "Id" => tag_id, "Name" => "Summer", "Type" => "UserTag", "Items" => tag_items("book-b", "book-c") },
      changed.sole.fetch("ChangedTag").fetch("Tag").slice("Id", "Name", "Type", "Items"))
    assert_equal [], synced_tags(cursor).first
    assert_equal "Summer", synced_tags.first.sole.fetch("NewTag").fetch("Tag").fetch("Name")

    2.times do
      delete "#{@base}/v1/library/tags/#{tag_id}"
      assert_response :ok
    end
    assert_equal [], synced_tags.first
    put "#{@base}/v1/library/tags/#{tag_id}", params: { Name: "Again" }, as: :json
    assert_response :not_found
    post "#{@base}/v1/library/tags/#{tag_id}/items", params: { Items: tag_items("book-a") }, as: :json
    assert_response :not_found
    assert_equal 0, @device.kobo_tags.count
  end

  test "collections belong to one reader and end with its connection" do
    post "#{@base}/v1/library/tags", params: { Name: "Mine", Items: tag_items("book-a") }, as: :json
    assert_response :created
    tag_id = response.parsed_body
    other, token = KoboDevice.issue(user: users(:two), name: "Other Kobo", base_url: @device.base_url)
    other.save!
    get "/kobo/#{token}/v1/library/sync"
    assert_equal [], response.parsed_body
    put "/kobo/#{token}/v1/library/tags/#{tag_id}", params: { Name: "Taken" }, as: :json
    assert_response :not_found
    post "/kobo/#{token}/v1/library/tags/#{tag_id}/items", params: { Items: tag_items("book-x") }, as: :json
    assert_response :not_found
    delete "/kobo/#{token}/v1/library/tags/#{tag_id}"
    assert_response :ok
    post "/kobo/#{token}/v1/library/tags", params: { Name: "Mine", Items: [] }, as: :json
    assert_not_equal tag_id, response.parsed_body
    assert_equal({ "name" => "Mine", "items" => tag_items("book-a") }, @device.kobo_tags.sole.attributes.slice("name", "items"))

    @device.rotate_token!
    post "#{@base}/v1/library/tags", params: { Name: "Late", Items: [] }, as: :json
    assert_response :unauthorized
    @device.destroy!
    assert_equal 0, KoboTag.where(kobo_device_id: @device.id).count
    assert_equal 1, other.kobo_tags.count
  end

  test "malformed, oversized and unbounded collection writes change nothing" do
    post "#{@base}/v1/library/tags", params: { Name: "Kept", Items: [] }, as: :json
    assert_response :created
    tag_id = response.parsed_body
    revision = @device.reload.sync_revision
    [ {}, { Name: "No items" }, { Items: [] }, { Name: 7, Items: [] }, { Name: "Bad", Items: "x" },
      { Name: "Bad", Items: [ "x" ] }, { Name: "Bad", Items: [ { Type: "ProductRevisionTagItem" } ] },
      { Name: "Bad", Items: [ { RevisionId: "../x", Type: "ProductRevisionTagItem" } ] } ].each do |body|
      post "#{@base}/v1/library/tags", params: body, as: :json
      assert_response :bad_request, body.inspect
    end
    post "#{@base}/v1/library/tags", params: "{", headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    post "#{@base}/v1/library/tags", params: { Name: "", Items: [] }, as: :json
    assert_response :unprocessable_content
    post "#{@base}/v1/library/tags", params: { Name: "x" * 256, Items: [] }, as: :json
    assert_response :unprocessable_content
    put "#{@base}/v1/library/tags/#{tag_id}", params: { Items: [] }, as: :json
    assert_response :bad_request
    post "#{@base}/v1/library/tags/#{tag_id}/items", params: { Name: "x" }, as: :json
    assert_response :bad_request
    post "#{@base}/v1/library/tags/#{tag_id}/items", params: { Items: tag_items("a" * 40) * 2 }.to_json + (" " * 65_536),
      headers: { "Content-Type" => "application/json" }
    assert_response :content_too_large
    post "#{@base}/v1/library/tags/#{tag_id}/items", params: { Items: tag_items(*Array.new(KoboTag::MAX_ITEMS + 1) { |index| "b#{index}" }) }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "name" => "Kept", "items" => [] }, @device.kobo_tags.sole.attributes.slice("name", "items"))
    assert_equal revision, @device.reload.sync_revision

    (KoboTag::MAX_PER_DEVICE - 1).times { |index| @device.kobo_tags.create!(tag_id: SecureRandom.uuid, name: "T#{index}", created_revision: 1, sync_revision: 1) }
    post "#{@base}/v1/library/tags", params: { Name: "One too many", Items: [] }, as: :json
    assert_response :unprocessable_content
    post "#{@base}/v1/library/tags", params: { Name: "Kept", Items: tag_items("book-a") }, as: :json
    assert_response :created
    assert_equal KoboTag::MAX_PER_DEVICE, @device.kobo_tags.count
  end

  test "requests Shelfarr does not support stay unsupported for a Shelfarr-only reader" do
    [ [ :get, "v1/products/featured/x" ], [ :post, "v1/user/profile" ], [ :put, "v1/user/wishlist" ], [ :get, "v1/analytics/event" ],
      [ :patch, "v1/library/tags/x" ], [ :delete, "v1/library/tags" ], [ :get, "v1/library/tags/x/items" ], [ :delete, "v1/library/#{@delivery.entitlement_id}" ] ].each do |verb, path|
      send(verb, "#{@base}/#{path}")
      assert_response :not_found, "#{verb} #{path}"
    end
    assert_not_requested :any, /kobo\.com/
  end

  test "coexistence still relays collections and optional Store requests to the reader's own Kobo account" do
    post "#{@base}/v1/library/tags", params: { Name: "Kept here", Items: [] }, as: :json
    assert_response :created
    coexist!
    created = stub_request(:post, "#{STORE}/v1/library/tags").to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: '"store-tag"')
    renamed = stub_request(:put, "#{STORE}/v1/library/tags/store-tag").to_return(status: 200)
    added = stub_request(:post, "#{STORE}/v1/library/tags/store-tag/items").to_return(status: 201)
    profile = stub_request(:get, "#{STORE}/v1/user/profile").to_return(headers: { "Content-Type" => "application/json" }, body: '{"Name":"Store"}')
    post "#{@base}/v1/library/tags", params: { Name: "Store", Items: [] }.to_json, headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_response :created
    assert_equal "store-tag", response.parsed_body
    put "#{@base}/v1/library/tags/store-tag", params: { Name: "Renamed" }.to_json, headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_response :ok
    post "#{@base}/v1/library/tags/store-tag/items", params: { Items: [] }.to_json, headers: kobo_headers.merge("Content-Type" => "application/json")
    assert_response :created
    get "#{@base}/v1/user/profile", headers: kobo_headers
    assert_equal({ "Name" => "Store" }, response.parsed_body)
    [ created, renamed, added, profile ].each { |stub| assert_requested stub }

    stub_request(:get, "#{STORE}/v1/library/sync").to_return(headers: { "Content-Type" => "application/json" }, body: "[]")
    get "#{@base}/v1/library/sync", headers: kobo_headers
    assert_equal [ "NewEntitlement" ], response.parsed_body.flat_map(&:keys), "collections kept in Shelfarr-only mode are not merged into the Store's"
    @device.update!(store_coexistence: false)
    assert_equal [ "Kept here" ], synced_tags.first.map { |item| item.fetch("NewTag").fetch("Tag").fetch("Name") }
  end
end
