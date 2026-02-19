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
        .with(query: hash_including("limit" => "500", "page" => "1"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-1",
                "title" => "The Hobbit",
                "author" => "J.R.R. Tolkien"
              }
            ],
            "total" => 1
          }.to_json
        )

      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "1"))
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
end
