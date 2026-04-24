# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncServiceTest < ActiveSupport::TestCase
  setup do
    LibraryItem.destroy_all
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "lib-ebook")
  end

  test "syncs items from configured libraries and removes stale entries" do
    LibraryItem.create!(library_id: "lib-audio", audiobookshelf_id: "ab-stale", title: "Old Title", author: "Old Author", synced_at: 1.day.ago)

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-1",
                "title" => "The Hobbit",
                "author" => "J.R.R. Tolkien",
                "media" => {
                  "metadata" => {
                    "subtitle" => "There and Back Again",
                    "narratorName" => "Andy Serkis",
                    "series" => [
                      { "name" => "Middle-earth", "sequence" => "0" }
                    ],
                    "publishedYear" => "1937",
                    "isbn" => "9780261103283"
                  }
                }
              }
            ],
            "total" => 1
          }.to_json
        )

      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-2",
                "title" => "Good Omens",
                "author" => "Neil Gaiman"
              }
            ],
            "total" => 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!
      assert result.success?
      assert_equal 2, result.items_synced
      assert_equal 2, result.libraries_synced
      assert_empty result.errors
      assert_equal 2, LibraryItem.count
      assert_not LibraryItem.exists?(audiobookshelf_id: "ab-stale")

      item = LibraryItem.find_by!(library_id: "lib-audio", audiobookshelf_id: "ab-1")
      assert_equal "There and Back Again", item.subtitle
      assert_equal "Andy Serkis", item.narrator
      assert_equal "Middle-earth", item.series
      assert_equal "0", item.series_position
      assert_equal 1937, item.published_year
      assert_equal "9780261103283", item.isbn
    end
  end

  test "returns false when no configurable libraries are available" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { libraries: [] }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert_not result.success?
      assert_equal "No Audiobookshelf library IDs configured or available.", result.errors.first
    end
  end

  test "syncs ebook library items when title and author only exist in media metadata" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "")

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ebook-1",
                "media" => {
                  "metadata" => {
                    "title" => "Project Hail Mary",
                    "authorName" => "Andy Weir"
                  }
                }
              }
            ],
            "total" => 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 1, result.items_synced
      assert_equal 1, result.libraries_synced
      assert_empty result.errors

      item = LibraryItem.find_by!(library_id: "lib-ebook", audiobookshelf_id: "ebook-1")
      assert_equal "Project Hail Mary", item.title
      assert_equal "Andy Weir", item.author
    end
  end

  test "persists missing items but excludes them from active inventory counts" do
    SettingsService.set(:audiobookshelf_ebook_library_id, "")

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-missing",
                "title" => "Lost Book",
                "author" => "Missing Author",
                "isMissing" => true
              }
            ],
            "total" => 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?

      item = LibraryItem.find_by!(library_id: "lib-audio", audiobookshelf_id: "ab-missing")
      assert item.missing?
      assert_equal 0, LibraryItem.available_for_matching.count
    end
  end
end
