# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_household_test_helper"

# A shared DRM-free copy reaching the recipient's own stock Kobo, and every
# reader boundary refusing it once the grant no longer holds.
class KoboHouseholdDeliveryTest < ActionDispatch::IntegrationTest
  include KoboHouseholdTestHelper

  setup do
    setup_kobo_household
    @share = share_with
    @copy = prepare_copy(viewer: @recipient)
    @device, @token = recipient_device
    @delivery = @device.send_account_book!(@copy, share: @share)
    @base = "/kobo/#{@token}"
  end

  teardown { teardown_kobo_household }

  def sync_items
    get "#{@base}/v1/library/sync"
    assert_response :success
    response.parsed_body
  end

  test "the recipient's reader syncs, downloads and resumes the private copy under its own entitlement" do
    item = sync_items.sole.fetch("NewEntitlement")
    assert_equal @delivery.entitlement_id, item.dig("BookEntitlement", "Id")
    assert_not_equal @shared_book.entitlement_id, item.dig("BookEntitlement", "Id")
    assert_equal "A Shared Purchase", item.dig("BookMetadata", "Title")
    url = item.dig("BookMetadata", "DownloadUrls").first.fetch("Url")
    assert_equal "https://shelfarr.example#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}", url
    assert_not_includes response.body, "kobo.com"
    get URI(url).path
    assert_response :success
    assert_equal synthetic_epub, response.body.b
    assert_not_nil @delivery.reload.last_download_at
    get URI(url).path, headers: { "Range" => "bytes=10-19" }
    assert_response :partial_content
    assert_equal synthetic_epub.byteslice(10, 10), response.body.b
    get "#{@base}/#{@delivery.entitlement_id}/100/150/false/image.jpg"
    assert_response :success
    assert_equal "image/png", response.media_type
  end

  test "reading places stay on the reader and never reach a library Book" do
    book = Book.create!(title: "A Shared Purchase", author: "An Author", book_type: :ebook, file_path: "/nowhere.epub")
    @device.update!(share_progress: true)
    @delivery.update_columns(last_download_at: Time.current)
    put "#{@base}/v1/library/#{@delivery.entitlement_id}/state", params: { ReadingStates: [ { CurrentBookmark: {
      ProgressPercent: 40, Location: { Source: "OEBPS/ch1.xhtml", Type: "KoboSpan" }, LastModified: Time.current.utc.iso8601(3) } } ] }, as: :json
    assert_response :success
    assert_equal 40, @delivery.reload.reading_state.dig("CurrentBookmark", "ProgressPercent")
    assert_equal [ "unsupported", "private_edition" ], @delivery.progress_bridge.values_at("status", "reason")
    assert_equal 0, ConsumerProgress.where(book: book).count
    assert_equal 0, ConsumerProgress.count
  end

  test "revoking the share stops sync, metadata, download, cover and state at once" do
    download = "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    @share.destroy!
    assert_empty sync_items
    get download
    assert_response :not_found
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/metadata"
    assert_response :not_found
    get "#{@base}/#{@delivery.entitlement_id}/100/150/false/image.jpg"
    assert_response :not_found
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/state"
    assert_response :not_found
  end

  test "an issued URL stops working without cleanup when the owner, recipient, title or copy changes" do
    download = "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    checks = [
      -> { @owner.update_columns(deleted_at: Time.current) },
      -> { @shared_book.update_columns(archived: true) },
      -> { @shared_book.update_columns(rights: "protected") },
      -> { @copy.update_columns(status: "failed") }
    ]
    checks.each do |change|
      change.call
      assert_empty sync_items
      get download
      assert_response :not_found
      @owner.update_columns(deleted_at: nil)
      @shared_book.update_columns(archived: false, rights: "drm_free")
      @copy.update_columns(status: "ready")
      get download
      assert_response :success
    end
    @recipient.update_columns(deleted_at: Time.current)
    get download
    assert_response :unauthorized
  end

  test "a new grant after revocation does not revive an earlier delivery" do
    @delivery.update_columns(kobo_account_share_id: nil)
    assert_not @delivery.reload.deliverable?, "a recipient delivery without its share must not pass as the owner's"
    @delivery.update_columns(kobo_account_share_id: @share.id)
    stale = @delivery.dup.tap { |copy| copy.entitlement_id = SecureRandom.uuid }
    @share.destroy!
    assert_equal 0, KoboDelivery.count
    regrant = share_with
    stale.kobo_account_share_id = @share.id
    assert_not Kobo::HouseholdAccess.delivery_allowed?(stale)
    stale.kobo_account_share_id = regrant.id
    assert Kobo::HouseholdAccess.delivery_allowed?(stale)
  end

  test "a changed or tampered cache file is refused instead of served" do
    path = File.join(@kobo_cache, @copy.storage_key)
    File.binwrite("#{path}.tmp", synthetic_epub)
    File.rename("#{path}.tmp", path)
    get "#{@base}/download/#{@delivery.entitlement_id}/#{@delivery.revision_id}"
    assert_response :gone
  end

  test "store coexistence never relays an ended shared entitlement to Kobo" do
    @device.update!(store_coexistence: true)
    @owner.update_columns(deleted_at: Time.current)
    get "#{@base}/v1/library/#{@delivery.entitlement_id}/metadata", headers: { "Authorization" => "Bearer reader-own" }
    assert_response :not_found
    assert_not_requested :get, /storeapi\.kobo\.com/, headers: { "Authorization" => "Bearer reader-own" }
  end

  test "sending a newer copy keeps entitlement and marks generations like library books" do
    @delivery.update_columns(last_download_at: Time.current)
    newer = prepare_copy(viewer: @recipient, bytes: synthetic_epub(version: "2.0"))
    again = @device.send_account_book!(newer, share: @share)
    assert_equal @delivery.entitlement_id, again.entitlement_id
    assert_not_equal @delivery.revision_id, again.revision_id
    assert again.progress_generation_ambiguous?
    assert_nil again.last_download_at
    assert KoboAccountBookFile.exists?(@copy.id), "a copy pinned by a delivery is never pruned"
  end
end
