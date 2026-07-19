# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260718114000_backfill_awaiting_purchase_requests")

class BackfillAwaitingPurchaseRequestsTest < ActiveSupport::TestCase
  LEGACY_MESSAGE =
    "2 DRM-free store offers found. Purchase from the seller and have the file imported " \
      "to complete this request, or retry to search again."

  test "migrates only legacy offer-backed requests and matching events and reverses them" do
    request = create_legacy_request(title: "Legacy Store Match", work_id: "OL_LEGACY_STORE_MATCH")
    request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "legacy-store-match",
      title: request.book.title,
      market: "PT",
      formats: [ "epub" ],
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/legacy-store-match/"
    )
    matching_event = request.request_events.create!(
      event_type: "attention_flagged",
      source: "request",
      level: :warn,
      message: LEGACY_MESSAGE,
      details: { "preserved" => true }
    )
    unrelated_event = request.request_events.create!(
      event_type: "attention_flagged",
      source: "request",
      level: :warn,
      message: "A different warning"
    )
    no_offer_request = create_legacy_request(title: "Legacy Without Offer", work_id: "OL_LEGACY_NO_OFFER")
    no_offer_event = no_offer_request.request_events.create!(
      event_type: "attention_flagged",
      source: "request",
      level: :warn,
      message: LEGACY_MESSAGE
    )

    BackfillAwaitingPurchaseRequests.new.up

    request.reload
    matching_event.reload
    assert request.awaiting_purchase?
    assert_not request.attention_needed?
    assert_nil request.issue_description
    assert_nil request.next_retry_at
    assert_equal "store_offers_found", matching_event.event_type
    assert_equal "store_provider", matching_event.source
    assert matching_event.info?
    assert_equal "DRM-free store offers found", matching_event.message
    assert_equal({ "preserved" => true }, matching_event.details)
    assert_equal "A different warning", unrelated_event.reload.message
    assert no_offer_request.reload.searching?
    assert no_offer_request.attention_needed?
    assert no_offer_event.reload.warn?

    BackfillAwaitingPurchaseRequests.new.down

    request.reload
    matching_event.reload
    assert request.searching?
    assert request.attention_needed?
    assert_equal BackfillAwaitingPurchaseRequests::LEGACY_DOWN_MESSAGE, request.issue_description
    assert_equal "attention_flagged", matching_event.event_type
    assert_equal "request", matching_event.source
    assert matching_event.warn?
    assert_equal BackfillAwaitingPurchaseRequests::LEGACY_DOWN_MESSAGE, matching_event.message
    assert_equal({ "preserved" => true }, matching_event.details)
    assert_equal "A different warning", unrelated_event.reload.message
    assert no_offer_request.reload.searching?
    assert_equal LEGACY_MESSAGE, no_offer_event.reload.message
  end

  private

  def create_legacy_request(title:, work_id:)
    book = Book.create!(
      title: title,
      book_type: :ebook,
      open_library_work_id: work_id
    )
    Request.create!(
      book: book,
      user: users(:one),
      status: :searching,
      attention_needed: true,
      issue_description: LEGACY_MESSAGE,
      next_retry_at: 1.day.from_now
    )
  end
end
