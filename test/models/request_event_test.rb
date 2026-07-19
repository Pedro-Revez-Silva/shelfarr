# frozen_string_literal: true

require "test_helper"

class RequestEventTest < ActiveSupport::TestCase
  test "record_latest updates one state event while ordinary events remain append-only" do
    request = requests(:pending_request)
    state_event = RequestEvent.record_latest!(
      request: request,
      event_type: "store_offers_found",
      source: "store_provider",
      message: "1 DRM-free store offer found",
      details: { offer_count: 1 }
    )
    original_updated_at = state_event.updated_at

    travel 1.minute do
      replacement = RequestEvent.record_latest!(
        request: request,
        event_type: "store_offers_found",
        source: "store_provider",
        message: "2 DRM-free store offers found",
        details: { offer_count: 2 }
      )

      assert_equal state_event.id, replacement.id
      assert_operator replacement.updated_at, :>, original_updated_at
    end

    2.times do
      RequestEvent.record!(
        request: request,
        event_type: "download_failed",
        source: "download",
        message: "A distinct failure"
      )
    end

    store_events = request.request_events.where(event_type: "store_offers_found", source: "store_provider")
    assert_equal 1, store_events.count
    assert_equal "2 DRM-free store offers found", store_events.sole.message
    assert_equal({ "offer_count" => 2 }, store_events.sole.details)
    assert_equal 2, request.request_events.where(event_type: "download_failed", source: "download").count
    assert_equal store_events.sole, request.request_events.recent.first
  end

  test "clear_latest removes only the matching state event" do
    request = requests(:pending_request)
    state_event = RequestEvent.record_latest!(
      request: request,
      event_type: "store_offers_found",
      source: "store_provider",
      message: "1 DRM-free store offer found"
    )
    ordinary_event = RequestEvent.record!(
      request: request,
      event_type: "download_failed",
      source: "download",
      message: "A distinct failure"
    )

    assert_equal 1, RequestEvent.clear_latest!(
      request: request,
      event_type: "store_offers_found",
      source: "store_provider"
    )

    assert_not RequestEvent.exists?(state_event.id)
    assert RequestEvent.exists?(ordinary_event.id)
  end
end
