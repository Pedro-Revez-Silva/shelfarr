# frozen_string_literal: true

require "test_helper"

class LibraryItemTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: %w[library_platform audiobookshelf_url bookorbit_url grimmory_url]).delete_all
  end

  test "audiobookshelf_url uses Audiobookshelf item route by default" do
    SettingsService.set(:audiobookshelf_url, "http://abs.example")
    item = LibraryItem.new(audiobookshelf_id: "abs-item-1")

    assert_equal "http://abs.example/item/abs-item-1", item.audiobookshelf_url
  end

  test "audiobookshelf_url uses BookOrbit book route when BookOrbit is active" do
    SettingsService.set(:library_platform, "bookorbit")
    SettingsService.set(:bookorbit_url, "http://bookorbit.example")
    item = LibraryItem.new(library_platform: "bookorbit", audiobookshelf_id: "42")

    assert_equal "http://bookorbit.example/book/42", item.audiobookshelf_url
  end

  test "audiobookshelf_url uses item platform rather than active platform" do
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "http://abs.example")
    SettingsService.set(:bookorbit_url, "http://bookorbit.example")
    item = LibraryItem.new(library_platform: "bookorbit", audiobookshelf_id: "42")

    assert_equal "http://bookorbit.example/book/42", item.audiobookshelf_url
  end

  test "audiobookshelf_url uses Grimmory book route when Grimmory is active" do
    SettingsService.set(:library_platform, "grimmory")
    SettingsService.set(:grimmory_url, "http://grimmory.example")
    item = LibraryItem.new(library_platform: "grimmory", audiobookshelf_id: "book-1")

    assert_equal "http://grimmory.example/book/book-1", item.audiobookshelf_url
  end

  test "display metadata is bounded and strips unsafe controls" do
    item = LibraryItem.new(
      title: "t" * LibraryItem::MAX_DISPLAY_TEXT_CHARACTERS,
      subtitle: "\u202ESubtitle only#{"x" * 1_000}",
      author: "Author\nName",
      narrator: "Narrator\xFF".dup.force_encoding(Encoding::UTF_8),
      publisher: "Publisher\u202EName",
      isbn: "978\n123"
    )

    assert_not item.display_title.start_with?(":")
    assert_not_includes item.display_title, "\u202E"
    assert_operator item.display_title.length, :<=, LibraryItem::MAX_DISPLAY_TEXT_CHARACTERS
    assert_equal "Author Name", item.display_author
    assert_equal "Narrated by Narrator�", item.detail_badges.last(2).first
    assert_equal "PublisherName", item.detail_badges.last
    assert_equal "ISBN 978 123", item.identifier_label
  end

  test "display title omits an empty title separator" do
    item = LibraryItem.new(title: nil, subtitle: "Subtitle only")

    assert_equal "Subtitle only", item.display_title
  end

  test "future sync times are treated as unknown" do
    item = LibraryItem.new(synced_at: 1.hour.from_now)

    assert_nil item.effective_synced_at
  end

  test "display badges remain bounded after Unicode case expansion" do
    item = LibraryItem.new(language: "ß" * LibraryItem::MAX_DISPLAY_TEXT_CHARACTERS)

    assert_operator item.detail_badges.first.length, :<=, LibraryItem::MAX_DISPLAY_TEXT_CHARACTERS
  end
end
