# frozen_string_literal: true

require "test_helper"

class LibraryItemTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: %w[library_platform audiobookshelf_url bookorbit_url]).delete_all
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
end
