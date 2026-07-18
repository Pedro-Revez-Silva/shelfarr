# frozen_string_literal: true

require "test_helper"

class StoreOfferTest < ActiveSupport::TestCase
  setup do
    @offer = StoreOffer.new(
      request: requests(:pending_request),
      provider: "ebooks_com",
      external_id: "347175270",
      title: "The Moonstone",
      formats: %w[epub pdf],
      market: "PT",
      drm_free: true,
      drm_type: "Watermarked",
      price_amount: BigDecimal("7.41"),
      price_currency: "EUR",
      localized_price: "7,41 €",
      storefront_url: "https://www.ebooks.com/en-pt/book/347175270/the-moonstone/wilkie-collins/"
    )
  end

  test "represents a confirmed DRM-free store offer" do
    assert @offer.valid?
    assert_equal "eBooks.com", @offer.provider_name
    assert_equal "7,41 €", @offer.display_price
    assert_equal %w[EPUB PDF], @offer.format_labels
    assert_equal "DRM-free (Watermarked)", @offer.drm_label
  end

  test "rejects protected offers" do
    @offer.drm_free = false

    assert_not @offer.valid?
  end

  test "rejects unsafe storefront and checkout URLs" do
    @offer.storefront_url = "https://attacker.example/book/1"
    @offer.checkout_url = "javascript:alert(1)"

    assert_not @offer.valid?
    assert_includes @offer.errors[:storefront_url], "must be a safe HTTPS URL"
    assert_includes @offer.errors[:checkout_url], "must be a safe HTTPS URL"
  end

  test "rejects nonstandard ports and unsafe cover hosts" do
    @offer.storefront_url = "https://www.ebooks.com:8443/book/1"
    @offer.cover_url = "https://attacker.example/cover.jpg"

    assert_not @offer.valid?
    assert_includes @offer.errors[:storefront_url], "must be a safe HTTPS URL"
    assert_includes @offer.errors[:cover_url], "must be a safe HTTPS URL"
  end

  test "rejects a product link localized for a different buyer market" do
    @offer.storefront_url = "https://www.ebooks.com/en-us/book/347175270/the-moonstone/"

    assert_not @offer.valid?
    assert_includes @offer.errors[:storefront_url], "must match the quoted buyer market and offer"
  end

  test "rejects a safe-hosted URL for a different product" do
    @offer.storefront_url = "https://www.ebooks.com/en-pt/book/999/the-moonstone/"

    assert_not @offer.valid?
    assert_includes @offer.errors[:storefront_url], "must match the quoted buyer market and offer"
  end

  test "rejects non-ISO markets and unsupported or repeated formats" do
    @offer.market = "XX"
    @offer.formats = %w[epub epub mobi]

    assert_not @offer.valid?
    assert_includes @offer.errors[:market], "must be a valid ISO 3166-1 country code"
    assert_includes @offer.errors[:formats], "must contain unique EPUB or PDF values"
  end

  test "bounds persisted upstream strings arrays and display controls" do
    @offer.title = "A" * (StoreOffer::MAX_TITLE_LENGTH + 1)
    @offer.isbns = Array.new(StoreOffer::MAX_ISBNS + 1, "9781480484160")
    @offer.localized_price = "EUR \u202E14.7"

    assert_not @offer.valid?
    assert @offer.errors[:title].any?
    assert @offer.errors[:isbns].any?
    assert_includes @offer.errors[:localized_price], "contains unsupported control characters"
  end

  test "requires coherent finite bounded price fields" do
    @offer.price_amount = nil
    @offer.price_currency = "EUR"
    @offer.localized_price = "EUR 7.41"

    assert_not @offer.valid?
    assert @offer.errors[:price_currency].any?
    assert @offer.errors[:localized_price].any?

    @offer.price_amount = BigDecimal("100000000")
    @offer.price_currency = "EURO"
    assert_not @offer.valid?
    assert @offer.errors[:price_amount].any?
    assert @offer.errors[:price_currency].any?
  end

  test "rejects future quote timestamps" do
    @offer.quoted_at = 1.hour.from_now

    assert_not @offer.valid?
    assert_includes @offer.errors[:quoted_at], "cannot be in the future"
  end

  test "identifies only currently usable quote timestamps as fresh" do
    now = Time.current

    assert StoreOffer.fresh_quote?(now - StoreOffer::FRESHNESS_TTL, now: now)
    assert StoreOffer.fresh_quote?(now + StoreOffer::MAX_FUTURE_QUOTE_SKEW, now: now)
    assert_not StoreOffer.fresh_quote?(now - StoreOffer::FRESHNESS_TTL - 1.second, now: now)
    assert_not StoreOffer.fresh_quote?(now + StoreOffer::MAX_FUTURE_QUOTE_SKEW + 1.second, now: now)
    assert_not StoreOffer.fresh_quote?(nil, now: now)
    assert_not StoreOffer.fresh_quote?("not-a-time", now: now)
  end

  test "falls back to currency and numeric price" do
    @offer.localized_price = nil

    assert_equal "EUR 7.41", @offer.display_price
  end

  test "creating a store offer does not rewrite encrypted acquisition credentials" do
    provider = AcquisitionProvider.create!(
      name: "Existing Secure Provider",
      url: "https://provider.example",
      api_key: "existing-secret"
    )
    ciphertext = provider.reload.api_key_before_type_cast

    @offer.save!

    assert_equal "existing-secret", provider.reload.api_key
    assert_equal ciphertext, provider.api_key_before_type_cast
  end

  test "database cascades store offers when an older application deletes a request directly" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending,
      created_via: "web",
      request_scope: "single"
    )
    @offer.request = request
    @offer.external_id = "legacy-delete-regression"
    @offer.storefront_url = "https://www.ebooks.com/en-pt/book/legacy-delete-regression/"
    @offer.save!

    assert_difference -> { Request.count }, -1 do
      assert_difference -> { StoreOffer.count }, -1 do
        Request.where(id: request.id).delete_all
      end
    end
  end
end
