# frozen_string_literal: true

require "test_helper"

class StoreProviderRegistryTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
  end

  teardown do
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
  end

  test "enables eBooks.com only for ebook requests" do
    assert_equal [ "ebooks_com" ], StoreProviderRegistry.enabled_for("ebook").map(&:key)
    assert_empty StoreProviderRegistry.enabled_for("audiobook")
    assert_empty StoreProviderRegistry.enabled_for("comicbook")
  end

  test "visible offers exclude expired quotes and completed requests" do
    request = requests(:pending_request)
    fresh = request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "fresh",
      title: request.book.title,
      formats: [ "epub" ],
      market: "PT",
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/fresh/fresh/",
      quoted_at: 1.hour.ago
    )
    request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "expired",
      title: request.book.title,
      formats: [ "epub" ],
      market: "PT",
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/expired/expired/",
      quoted_at: StoreOffer::FRESHNESS_TTL.ago - 1.minute
    )

    assert_equal [ fresh ], StoreProviderRegistry.visible_offers_for(request).to_a

    request.complete!
    assert_empty StoreProviderRegistry.visible_offers_for(request)
  end
end
