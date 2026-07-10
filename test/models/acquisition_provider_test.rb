# frozen_string_literal: true

require "test_helper"

class AcquisitionProviderTest < ActiveSupport::TestCase
  test "normalizes trailing slash from URL" do
    provider = AcquisitionProvider.create!(
      name: "Provider",
      url: "http://provider.test/",
      supports_ebooks: true,
      supports_audiobooks: false
    )

    assert_equal "http://provider.test", provider.url
  end

  test "requires http or https URL" do
    provider = AcquisitionProvider.new(name: "Provider", url: "file:///tmp/provider")

    assert_not provider.valid?
    assert_includes provider.errors[:url], "must be a valid http or https URL"
  end

  test "rejects private network URLs unless allow_private_network is enabled" do
    provider = AcquisitionProvider.new(name: "Provider", url: "http://localhost:4567")

    assert_not provider.valid?
    assert_match(/private network address/, provider.errors[:url].first)

    provider.url = "http://192.168.1.80:4567"
    assert_not provider.valid?
    assert_match(/private network address/, provider.errors[:url].first)

    provider.allow_private_network = true
    assert provider.valid?, provider.errors.full_messages.join(", ")
  end

  test "requires at least one media type" do
    provider = AcquisitionProvider.new(
      name: "Provider",
      url: "http://provider.test",
      supports_ebooks: false,
      supports_audiobooks: false
    )

    assert_not provider.valid?
    assert_includes provider.errors[:base], "Provider must support ebooks, audiobooks, or Comics & Manga"
  end

  test "filters by book type" do
    ebook_provider = AcquisitionProvider.create!(
      name: "Ebook Provider",
      url: "http://ebooks.test",
      supports_ebooks: true,
      supports_audiobooks: false
    )
    audiobook_provider = AcquisitionProvider.create!(
      name: "Audiobook Provider",
      url: "http://audio.test",
      supports_ebooks: false,
      supports_audiobooks: true
    )

    assert_includes AcquisitionProvider.for_book_type("ebook"), ebook_provider
    assert_not_includes AcquisitionProvider.for_book_type("ebook"), audiobook_provider
    assert_includes AcquisitionProvider.for_book_type("audiobook"), audiobook_provider
    assert_not_includes AcquisitionProvider.for_book_type("audiobook"), ebook_provider
  end

  test "encrypts api_key" do
    provider = AcquisitionProvider.create!(
      name: "Secure Provider",
      url: "http://secure-provider.test",
      api_key: "secret-provider-token"
    )

    provider.reload
    assert_equal "secret-provider-token", provider.api_key
    assert_not_equal "secret-provider-token", provider.api_key_before_type_cast
  end
end
