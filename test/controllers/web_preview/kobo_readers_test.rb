# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class WebPreview::KoboReadersTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include KoboTestHelper

  setup do
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = users(:one)
    @admin = users(:two)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    prepare_kobo_book
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def send_json(method, path, user: @member, **body)
    public_send(method, path, params: body, headers: account_headers(user), as: :json)
    response.parsed_body
  end

  def reader(device = @device, user: @member)
    preview_get web_preview_api_kobo_reader_path(device), user: user
    assert_response :success
    response.parsed_body.fetch("reader")
  end

  def endpoint_token(body)
    body.dig("setup", "endpoint")[%r{/kobo/([0-9a-f]{64})\z}, 1]
  end

  test "the list shows only the signed-in person's readers, with defaults for a new one, even to an administrator" do
    theirs, = KoboDevice.issue(user: @admin, name: "Admin's Kobo", base_url: "https://shelfarr.example")
    theirs.save!
    sign_in_as(@member)
    preview_get web_preview_api_kobo_readers_path
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal @member.id.to_s, body.fetch("account")
    assert_equal [ "My Kobo" ], body.fetch("readers").map { |entry| entry.fetch("name") }
    row = body.fetch("readers").sole
    assert_equal %w[id name mode mode_label store_coexistence share_progress receive_progress base_url last_sync_at version], row.keys
    assert_equal [ "shelfarr_only", "Shelfarr books only", nil ], row.values_at("mode", "mode_label", "last_sync_at")
    assert_equal({ "base_url" => "http://www.example.com", "store_coexistence" => false, "share_progress" => true, "receive_progress" => false }, body.fetch("new_reader"))
    assert_not_includes response.body, @device.token_digest
    assert_not_includes response.body, @token

    sign_in_as(@admin)
    preview_get web_preview_api_kobo_readers_path, user: @admin
    assert_equal [ "Admin's Kobo" ], response.parsed_body.fetch("readers").map { |entry| entry.fetch("name") }
    preview_get web_preview_api_kobo_reader_path(@device), user: @admin
    assert_response :not_found
    assert_equal "reader_not_found", response.parsed_body.fetch("error")
    send_json(:post, web_preview_api_kobo_reader_revoke_path(@device), user: @admin, version: WebPreview::KoboReaderJson.version(@device))
    assert_response :not_found
    assert KoboDevice.exists?(@device.id)
  end

  test "connecting a reader shows its address once with no-store and no-referrer, and never again" do
    sign_in_as(@member)
    body = send_json(:post, web_preview_api_account_kobo_readers_path, name: " Clara ", base_url: "https://reader.example/shelfarr/", store_coexistence: true, share_progress: true, receive_progress: false)
    assert_response :created
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    token = endpoint_token(body)
    device = KoboDevice.authenticate(token)
    assert_equal [ "Clara", "https://reader.example/shelfarr", true, true, false ], [ device.name, device.base_url, device.store_coexistence, device.share_progress, device.receive_progress ]
    assert_equal({ "endpoint" => "https://reader.example/shelfarr/kobo/#{token}", "store_endpoint" => KoboDevice::STORE_ENDPOINT }, body.fetch("setup"))
    assert_equal device.id.to_s, body.dig("reader", "id")
    assert_not_includes device.attributes.values, token

    preview_get web_preview_api_kobo_reader_path(device)
    assert_not_includes response.body, token
    preview_get web_preview_api_kobo_readers_path
    assert_not_includes response.body, token
    assert_not_includes Rails.root.join("log/test.log").read.lines.last(200).join, token
  end

  test "a new reader is refused with its fields when the address is unsafe or keeping the Store lacks HTTPS" do
    sign_in_as(@member)
    [ "file:///etc/passwd", "https://user:pass@example.com", "https://example.com?private=yes", "broken" ].each do |base_url|
      assert_no_difference "KoboDevice.count" do
        body = send_json(:post, web_preview_api_account_kobo_readers_path, name: "Reader", base_url: base_url, store_coexistence: false, share_progress: true, receive_progress: false)
        assert_response :unprocessable_entity
        assert_equal "invalid_reader", body.fetch("error")
        assert body.fetch("errors").key?("base_url")
      end
    end
    body = send_json(:post, web_preview_api_account_kobo_readers_path, name: "Reader", base_url: "http://shelfarr.local:3000", store_coexistence: true, share_progress: true, receive_progress: false)
    assert_equal({ "base_url" => [ "must use HTTPS to keep the Kobo Store on this reader" ] }, body.fetch("errors"))
    assert_equal [ "Base url must use HTTPS to keep the Kobo Store on this reader" ], body.fetch("messages")
    body = send_json(:post, web_preview_api_account_kobo_readers_path, name: "", base_url: "http://shelfarr.local:3000", store_coexistence: false, share_progress: true, receive_progress: false)
    assert_equal [ "can't be blank" ], body.dig("errors", "name")
    send_json(:post, web_preview_api_account_kobo_readers_path, name: "Reader", base_url: "http://shelfarr.local:3000", store_coexistence: "false", share_progress: true, receive_progress: false)
    assert_response :bad_request
    send_json(:post, web_preview_api_account_kobo_readers_path, name: "Reader", base_url: "http://shelfarr.local:3000")
    assert_response :bad_request
  end

  test "a pasted connection address is refused as the Shelfarr address and never logged or shown" do
    sign_in_as(@member)
    pasted = "https://shelfarr.example/shelf/kobo/#{@token}"
    assert_no_difference "KoboDevice.count" do
      body = send_json(:post, web_preview_api_account_kobo_readers_path, name: "Copy", base_url: pasted, store_coexistence: true, share_progress: true, receive_progress: false)
      assert_response :unprocessable_entity
      assert_equal({ "base_url" => [ "must be Shelfarr's own address, not a Kobo connection address" ] }, body.fetch("errors"))
      assert_not_includes response.body, @token
    end
    assert_not_includes Rails.root.join("log/test.log").read.lines.last(200).join, @token

    @device.update_columns(base_url: pasted)
    preview_get web_preview_api_kobo_readers_path
    assert_equal "https://shelfarr.example/shelf/kobo/…", response.parsed_body.fetch("readers").sole.fetch("base_url")
    assert_not_includes response.body, @token
  end

  test "writes need the page's account and a valid CSRF token, and a signed-out request is refused" do
    preview_get web_preview_api_kobo_readers_path
    assert_response :unauthorized
    sign_in_as(@member)
    post web_preview_api_account_kobo_readers_path, params: { name: "X", base_url: "https://a.example", store_coexistence: true, share_progress: true, receive_progress: false },
      headers: account_headers(@admin), as: :json
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    with_forgery_protection do
      token = csrf_token
      assert_no_difference "KoboDevice.count" do
        post web_preview_api_account_kobo_readers_path, params: { name: "X", base_url: "https://a.example", store_coexistence: true, share_progress: true, receive_progress: false },
          headers: account_headers(@member), as: :json
      end
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      assert_difference "KoboDevice.count", 1 do
        post web_preview_api_account_kobo_readers_path, params: { name: "X", base_url: "https://a.example", store_coexistence: true, share_progress: true, receive_progress: false },
          headers: account_headers(@member).merge("X-CSRF-Token" => token), as: :json
      end
    end
  end

  test "a person outside the preview cannot use the API" do
    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    sign_in_as(@member)
    preview_get web_preview_api_kobo_readers_path
    assert_response :not_found
    send_json(:post, web_preview_api_kobo_reader_revoke_path(@device), version: "x")
    assert_response :not_found
    assert KoboDevice.exists?(@device.id)
  end

  test "settings save with the version on screen, say what happens next, and refuse a stale version" do
    sign_in_as(@member)
    detail = reader
    assert_equal [ false, false, false ], detail.values_at("store_coexistence", "share_progress", "receive_progress")
    body = send_json(:put, web_preview_api_kobo_reader_path(@device), version: detail.fetch("version"), store_coexistence: false, share_progress: true, receive_progress: true)
    assert_response :success
    assert_equal "My Kobo receives Shelfarr reading places for books sent from your library at its next Wi-Fi sync.", body.fetch("notice")
    assert @device.reload.receive_progress?
    assert_not_equal detail.fetch("version"), body.dig("reader", "version")

    stale = send_json(:put, web_preview_api_kobo_reader_path(@device), version: detail.fetch("version"), store_coexistence: false, share_progress: false, receive_progress: false)
    assert_response :conflict
    assert_equal "reader_changed", stale.fetch("error")
    assert stale.dig("reader", "receive_progress")
    assert @device.reload.share_progress?
    assert @device.receive_progress?

    @device.update_columns(base_url: "http://shelfarr.local")
    refused = send_json(:put, web_preview_api_kobo_reader_path(@device), version: body.dig("reader", "version"), store_coexistence: true, share_progress: true, receive_progress: true)
    assert_response :unprocessable_entity
    assert_equal({ "base_url" => [ "must use HTTPS to keep the Kobo Store on this reader" ] }, refused.fetch("errors"))
    assert_not @device.reload.store_coexistence?
  end

  test "a new connection address replaces the old one only from the current version, once, with no-referrer" do
    sign_in_as(@member)
    version = reader.fetch("version")
    body = send_json(:post, web_preview_api_kobo_reader_connection_address_path(@device), version: version)
    assert_response :success
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    token = endpoint_token(body)
    assert_nil KoboDevice.authenticate(@token)
    assert_equal @device, KoboDevice.authenticate(token)

    again = send_json(:post, web_preview_api_kobo_reader_connection_address_path(@device), version: version)
    assert_response :conflict
    assert_equal "reader_changed", again.fetch("error")
    assert_equal @device, KoboDevice.authenticate(token)
    assert_not_includes response.body, token
  end

  test "revoking removes the reader and its access, keeping the library book, only from the version on screen" do
    @device.send_book!(@book)
    sign_in_as(@member)
    shown = reader.fetch("version")
    send_json(:post, web_preview_api_kobo_reader_revoke_path(@device))
    assert_response :bad_request
    rotated = send_json(:post, web_preview_api_kobo_reader_connection_address_path(@device), version: shown)
    fresh = endpoint_token(rotated)
    stale = send_json(:post, web_preview_api_kobo_reader_revoke_path(@device), version: shown)
    assert_response :conflict
    assert_equal "reader_changed", stale.fetch("error")
    assert_equal @device, KoboDevice.authenticate(fresh)
    body = send_json(:post, web_preview_api_kobo_reader_revoke_path(@device), version: rotated.dig("reader", "version"))
    assert_response :success
    assert_equal({ "account" => @member.id.to_s, "revoked" => @device.id.to_s, "notice" => "Kobo connection revoked. Books already on the reader are kept." }, body)
    assert_nil KoboDevice.authenticate(fresh)
    assert Book.exists?(@book.id)
    send_json(:post, web_preview_api_kobo_reader_revoke_path(@device), version: rotated.dig("reader", "version"))
    assert_response :not_found
    assert_equal "reader_not_found", response.parsed_body.fetch("error")
  end

  test "a book's Kobo panel lists only the person's readers and says when the file cannot be sent" do
    theirs, = KoboDevice.issue(user: @admin, name: "Admin's Kobo", base_url: "https://shelfarr.example")
    theirs.save!
    sign_in_as(@member)
    preview_get web_preview_api_library_kobo_path(@book)
    assert_response :success
    assert_equal({ "readers" => [ { "id" => @device.id.to_s, "name" => "My Kobo" } ], "refusal" => nil }, response.parsed_body.fetch("kobo"))

    pdf = File.join(@root, "Other.pdf")
    File.write(pdf, "%PDF-1.4")
    other = Book.create!(title: "A PDF", author: "Someone", book_type: :ebook, file_path: pdf)
    preview_get web_preview_api_library_kobo_path(other)
    assert_equal "Kobo sync supports EPUB files only", response.parsed_body.dig("kobo", "refusal")
    missing = Book.create!(title: "Gone", author: "Someone", book_type: :ebook, file_path: File.join(@root, "gone.epub"))
    preview_get web_preview_api_library_kobo_path(missing)
    assert_equal "The EPUB is missing or outside the authorized library", response.parsed_body.dig("kobo", "refusal")
    audiobook = Book.create!(title: "Heard", author: "Someone", book_type: :audiobook, file_path: @root)
    preview_get web_preview_api_library_kobo_path(audiobook)
    assert_equal "Choose an acquired ebook", response.parsed_body.dig("kobo", "refusal")
    locked = File.join(@root, "Locked.epub")
    write_epub(locked, extra: { "META-INF/encryption.xml" => "<encryption/>" })
    protected_book = Book.create!(title: "Locked", author: "Someone", book_type: :ebook, file_path: locked)
    preview_get web_preview_api_library_kobo_path(protected_book)
    assert_equal "Encrypted EPUBs are not supported", response.parsed_body.dig("kobo", "refusal")
    wanted = Book.create!(title: "Wanted", author: "Someone", book_type: :ebook)
    preview_get web_preview_api_library_kobo_path(wanted)
    assert_response :not_found
  end

  test "sending a library book queues it for the person's own reader with the classic wording" do
    sign_in_as(@member)
    body = send_json(:post, web_preview_api_kobo_reader_send_path(@device), book_id: @book.id.to_s)
    assert_response :success
    assert_equal "Queued for My Kobo. Sync your Kobo over Wi-Fi to download it.", body.fetch("notice")
    delivery = @device.kobo_deliveries.sole
    assert_equal @book, delivery.book

    detail = reader
    row = detail.fetch("deliveries").sole
    assert_equal({ "kind" => "library", "publication_id" => @book.id.to_s }, row.fetch("link"))
    assert_equal [ "A Library Book", "library", "Queued · waiting for download" ], row.values_at("title", "source", "status")
    assert_equal "Sent as EPUB: Shelfarr couldn't safely prepare a Kobo edition (it has no XHTML chapters)", row.fetch("edition")
    assert_equal({ "book_id" => @book.id.to_s, "confirmation" => nil }, row.fetch("send_again"))
    assert_nil row.fetch("place")
    assert_nil row.fetch("outbound")

    pdf = File.join(@root, "Other.pdf")
    File.write(pdf, "%PDF-1.4")
    other = Book.create!(title: "A PDF", author: "Someone", book_type: :ebook, file_path: pdf)
    refused = send_json(:post, web_preview_api_kobo_reader_send_path(@device), book_id: other.id.to_s)
    assert_response :unprocessable_entity
    assert_equal({ "error" => "kobo_send_refused", "message" => "Kobo sync supports EPUB files only" }, refused)
    send_json(:post, web_preview_api_kobo_reader_send_path(@device), book_id: Book.create!(title: "Wanted", book_type: :ebook).id.to_s)
    assert_equal "book_not_found", response.parsed_body.fetch("error")
    send_json(:post, web_preview_api_kobo_reader_send_path(@device), book_id: 12)
    assert_response :bad_request

    theirs, = KoboDevice.issue(user: @admin, name: "Admin's Kobo", base_url: "https://shelfarr.example")
    theirs.save!
    send_json(:post, web_preview_api_kobo_reader_send_path(theirs), book_id: @book.id.to_s)
    assert_response :not_found
    assert_empty theirs.kobo_deliveries
  end

  test "an unapplied Kobo place is shown with the classic wording and chosen explicitly, once" do
    @device.update!(share_progress: true, store_coexistence: true, store_status: "unavailable", store_checked_at: 1.minute.ago)
    delivery = @device.send_book!(@book)
    asset = Consumer::LibraryAssets.new(@book).list.sole.id
    Consumer::ProgressWriter.new(user: @member, book: @book).call("asset_id" => asset, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => 1.minute.ago.utc.iso8601(3), "locator" => { "href" => "a.xhtml", "locations" => { "totalProgression" => 0.8 } })
    delivery.update_columns(progress_bridge: { "status" => "superseded", "percent" => 35.0, "observed_at" => 2.hours.ago.utc.iso8601(3),
      "asset_id" => asset, "locator" => { "href" => "b.xhtml", "type" => "application/xhtml+xml", "locations" => { "totalProgression" => 0.35 } } })
    sign_in_as(@member)
    detail = reader
    assert_equal({ "tone" => "warning", "text" => "Kobo Store couldn't be reached 1 minute ago. Shelfarr books still synced; Store changes arrive at a later sync.", "choosable" => false }, detail.fetch("store_status"))
    place = detail.fetch("deliveries").sole.fetch("place")
    assert_equal [ "choice", true ], place.values_at("tone", "choosable")
    assert_match(/Kept a newer place from another device \(80%, read 1 minute ago\). Kobo place: 35%, read about 2 hours ago/, place.fetch("text"))

    shown = detail.fetch("deliveries").sole.fetch("choice")
    newer = delivery.progress_bridge.merge("percent" => 55.0, "locator" => delivery.progress_bridge["locator"].merge("locations" => { "totalProgression" => 0.55 }))
    original = delivery.progress_bridge
    delivery.update_columns(progress_bridge: newer)
    moved = send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: delivery.entitlement_id, choice: shown)
    assert_response :conflict
    assert_equal [ "place_refused", "This book's reading places changed after the page was shown. Review them and choose again." ], moved.values_at("error", "message")
    assert_equal "a.xhtml", @member.consumer_progresses.find_by!(book: @book).locator["href"]
    delivery.update_columns(progress_bridge: original)
    send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: delivery.entitlement_id)
    assert_response :bad_request

    body = send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: delivery.entitlement_id, choice: shown)
    assert_response :success
    assert_equal "Shelfarr now resumes A Library Book at the Kobo place.", body.fetch("notice")
    assert_equal "b.xhtml", @member.consumer_progresses.find_by!(book: @book).locator["href"]
    assert_not body.fetch("reader").fetch("deliveries").sole.dig("place", "choosable")

    again = send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: delivery.entitlement_id, choice: body.fetch("reader").fetch("deliveries").sole.fetch("choice"))
    assert_response :conflict
    assert_equal [ "place_refused", "There is no unapplied Kobo place for this book." ], again.values_at("error", "message")
    unknown = send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: SecureRandom.uuid, choice: "x")
    assert_equal "This book is no longer selected for My Kobo. Review the list again.", unknown.fetch("message")

    delivery.update_columns(progress_bridge: delivery.progress_bridge.merge("status" => "superseded"))
    File.rename(@path, "#{@path}.old")
    write_epub(@path)
    changed = send_json(:post, web_preview_api_kobo_reader_kobo_place_path(@device), entitlement_id: delivery.entitlement_id, choice: reader.fetch("deliveries").sole.fetch("choice"))
    assert_equal "That Kobo place belongs to an edition that is no longer in the library.", changed.fetch("message")
  end

  test "a Shelfarr place that needs a choice is sent explicitly only from the owner's reader" do
    prepare_kobo_kepub
    @device.update!(receive_progress: true)
    delivery = @device.send_book!(@book)
    delivery.update!(last_download_at: 1.hour.ago)
    asset = Consumer::LibraryAssets.new(@book).list.sole.id
    Consumer::ProgressWriter.new(user: @member, book: @book).call("asset_id" => asset, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "locator" => { "href" => "OEBPS/Text/ch2.xhtml", "locations" => { "progression" => 0.5, "totalProgression" => 0.4 } })
    sign_in_as(@member)
    shown = reader.fetch("deliveries").sole
    outbound = shown.fetch("outbound")
    assert_equal [ "choice", true ], outbound.values_at("tone", "choosable")
    assert_match(/Shelfarr's place \(chapter 2 of 3, 40% of the book\) has no reading time/, outbound.fetch("text"))

    delivery.update_columns(reading_state: { "CurrentBookmark" => { "ProgressPercent" => 90, "Location" => { "Value" => "kobo.9.1" } } })
    read_on = send_json(:post, web_preview_api_kobo_reader_shelfarr_place_path(@device), entitlement_id: delivery.entitlement_id, choice: shown.fetch("choice"))
    assert_response :conflict
    assert_equal "This book's reading places changed after the page was shown. Review them and choose again.", read_on.fetch("message")
    assert_not_equal "queued", delivery.reload.progress_outbound["status"]

    progress = @member.consumer_progresses.sole
    Consumer::ProgressWriter.new(user: @member, book: @book).call("asset_id" => asset, "expected_version" => progress.version,
      "client_mutation_id" => SecureRandom.uuid, "locator" => { "href" => "OEBPS/Text/ch3.xhtml", "locations" => { "progression" => 0.5, "totalProgression" => 0.6 } })
    moved = send_json(:post, web_preview_api_kobo_reader_shelfarr_place_path(@device), entitlement_id: delivery.entitlement_id, choice: shown.fetch("choice"))
    assert_response :conflict
    assert_equal "This book's reading places changed after the page was shown. Review them and choose again.", moved.fetch("message")
    assert_not_equal "queued", delivery.reload.progress_outbound["status"]
    current = moved.fetch("reader").fetch("deliveries").sole
    assert_match(/chapter 3 of 3, 60% of the book/, current.dig("outbound", "text"))

    body = send_json(:post, web_preview_api_kobo_reader_shelfarr_place_path(@device), entitlement_id: delivery.entitlement_id, choice: current.fetch("choice"))
    assert_equal "My Kobo moves A Library Book to the Shelfarr place at its next Wi-Fi sync.", body.fetch("notice")
    assert_match(/Your chosen Shelfarr place \(chapter 3 of 3, 60% of the book\) waits/, body.fetch("reader").fetch("deliveries").sole.dig("outbound", "text"))
    again = send_json(:post, web_preview_api_kobo_reader_shelfarr_place_path(@device), entitlement_id: delivery.entitlement_id, choice: body.fetch("reader").fetch("deliveries").sole.fetch("choice"))
    assert_equal "There is no Shelfarr place waiting for a choice for this book. Its place may have changed; review it again.", again.fetch("message")
  end

  test "classic reader pages open the warm pages for preview users and stay classic otherwise" do
    sign_in_as(@member)
    get kobo_devices_path
    assert_redirected_to "/preview/account/devices#kobo-readers"
    get kobo_device_path(@device)
    assert_redirected_to "/preview/account/devices/kobo/#{@device.id}"
    theirs, = KoboDevice.issue(user: @admin, name: "Admin's Kobo", base_url: "https://shelfarr.example")
    theirs.save!
    get kobo_device_path(theirs)
    assert_response :not_found

    post rotate_kobo_device_path(@device)
    assert_response :success
    assert_select "[data-testid=kobo-endpoint]"
    patch kobo_device_path(@device), params: { kobo_device: { receive_progress: "1" } }
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "My Kobo"

    get web_preview_kobo_reader_path(@device)
    assert_response :success

    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    get kobo_devices_path
    assert_response :success
    get kobo_device_path(@device)
    assert_response :success
    get web_preview_kobo_reader_path(@device)
    assert_response :not_found
  end
end
