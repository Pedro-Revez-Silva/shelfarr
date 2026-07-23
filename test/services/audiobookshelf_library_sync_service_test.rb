# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncServiceTest < ActiveSupport::TestCase
  setup do
    LibraryItem.destroy_all
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "lib-ebook")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "")
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
    SettingsService.set(:audiobookshelf_comicbook_library_id, "")
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

  test "syncs configured comic book library items" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "lib-comics")

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-comics/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "comic-1",
                "title" => "Saga #1",
                "author" => "Brian K. Vaughan"
              }
            ],
            "total" => 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 1, result.items_synced
      assert_equal 1, result.libraries_synced
      assert_equal "Saga #1", LibraryItem.find_by!(library_id: "lib-comics", audiobookshelf_id: "comic-1").title
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

  test "sync scopes cached items to the active library platform" do
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "42",
      audiobookshelf_id: "101",
      title: "Audiobookshelf Copy",
      author: "Original Author",
      synced_at: 1.day.ago
    )

    SettingsService.set(:library_platform, "bookorbit")
    SettingsService.set(:bookorbit_url, "http://localhost:3000")
    SettingsService.set(:bookorbit_username, "admin")
    SettingsService.set(:bookorbit_password, "secret")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "42")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    LibraryPlatformClient.reset_connections!

    VCR.turned_off do
      stub_request(:post, "http://localhost:3000/api/v1/auth/login")
        .with(body: { username: "admin", password: "secret" }.to_json)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { accessToken: "bookorbit-token" }.to_json)
      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            items: [
              { id: 101, status: "present", title: "BookOrbit Copy", authors: [ "New Author" ] }
            ],
            total: 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 2, LibraryItem.count
      assert_equal "Audiobookshelf Copy", LibraryItem.find_by!(library_platform: "audiobookshelf", library_id: "42", audiobookshelf_id: "101").title
      assert_equal "BookOrbit Copy", LibraryItem.find_by!(library_platform: "bookorbit", library_id: "42", audiobookshelf_id: "101").title
      assert_equal [ "BookOrbit Copy" ], LibraryItem.available_for_matching.pluck(:title)
    end
  ensure
    LibraryPlatformClient.reset_connections!
  end

  test "syncs library items through Grimmory facade" do
    SettingsService.set(:library_platform, "grimmory")
    SettingsService.set(:grimmory_url, "http://localhost:5173")
    SettingsService.set(:grimmory_username, "admin")
    SettingsService.set(:grimmory_password, "secret")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "grim-lib")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    LibraryPlatformClient.reset_connections!

    VCR.turned_off do
      stub_request(:post, "http://localhost:5173/api/v1/auth/login")
        .with(body: { username: "admin", password: "secret" }.to_json)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessToken: "grimmory-token" }.to_json
        )
      stub_request(:get, "http://localhost:5173/api/v1/libraries/grim-lib/book")
        .with(headers: { "Authorization" => "Bearer grimmory-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "id" => "grim-1",
              "title" => "Nettle & Bone",
              "authors" => [ "T. Kingfisher" ],
              "publishedYear" => 2022
            }
          ].to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 1, result.items_synced
      item = LibraryItem.find_by!(library_platform: "grimmory", library_id: "grim-lib", audiobookshelf_id: "grim-1")
      assert_equal "Nettle & Bone", item.title
      assert_equal "T. Kingfisher", item.author
      assert_equal 2022, item.published_year
    end
  ensure
    LibraryPlatformClient.reset_connections!
  end

  test "syncs items from additional scan library ids alongside delivery libraries" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "")
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "lib-scifi, lib-fantasy")

    VCR.turned_off do
      [ "lib-audio", "lib-scifi", "lib-fantasy" ].each_with_index do |lib_id, idx|
        stub_request(:get, %r{localhost:13378/api/libraries/#{lib_id}/items})
          .with(query: hash_including("limit" => "500", "page" => "0"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "results" => [
                {
                  "id" => "item-#{idx}",
                  "title" => "Title #{lib_id}",
                  "author" => "Author #{lib_id}"
                }
              ],
              "total" => 1
            }.to_json
          )
      end

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 3, result.items_synced
      assert_equal 3, result.libraries_synced
      assert_equal 3, LibraryItem.count
      assert LibraryItem.exists?(library_id: "lib-audio", audiobookshelf_id: "item-0")
      assert LibraryItem.exists?(library_id: "lib-scifi", audiobookshelf_id: "item-1")
      assert LibraryItem.exists?(library_id: "lib-fantasy", audiobookshelf_id: "item-2")
    end
  ensure
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "")
  end

  test "scan library ids are deduplicated against delivery library ids" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "")
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "lib-audio, lib-extra")

    VCR.turned_off do
      [ "lib-audio", "lib-extra" ].each_with_index do |lib_id, idx|
        stub_request(:get, %r{localhost:13378/api/libraries/#{lib_id}/items})
          .with(query: hash_including("limit" => "500", "page" => "0"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "results" => [ { "id" => "item-#{idx}", "title" => "Title #{lib_id}", "author" => "Author" } ],
              "total" => 1
            }.to_json
          )
      end

      result = AudiobookshelfLibrarySyncService.new.sync!

      assert result.success?
      assert_equal 2, result.libraries_synced
      assert_equal 2, LibraryItem.count
    end
  end

  test "does not prune cached items when library sync fails with a transient API failure" do
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-audio",
      audiobookshelf_id: "ab-existing",
      title: "Existing Title",
      author: "Author",
      synced_at: 1.day.ago
    )

    VCR.turned_off do
      # lib-audio fails (non-200)
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .to_return(status: 500)

      # lib-ebook succeeds
      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [ { "id" => "ab-2", "title" => "Good Omens", "author" => "Neil Gaiman" } ],
            "total" => 1
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!

      # It should capture the failure for lib-audio in result.errors
      assert_includes result.errors.first, "returned status 500"

      # The existing item in lib-audio should NOT be pruned because the sync failed!
      assert LibraryItem.exists?(audiobookshelf_id: "ab-existing")

      # The item in lib-ebook should be successfully synced
      assert LibraryItem.exists?(audiobookshelf_id: "ab-2")
    end
  end

  test "prunes cached items for libraries no longer in the configured set" do
    # Create library items for a library that is not configured (e.g. lib-old)
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-old",
      audiobookshelf_id: "ab-old",
      title: "Old Library Item",
      author: "Author",
      synced_at: 1.day.ago
    )
    # Also create one for a configured library to ensure it's not deleted if it's synced
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-audio",
      audiobookshelf_id: "ab-existing",
      title: "Existing Title",
      author: "Author",
      synced_at: 1.day.ago
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [ { "id" => "ab-existing", "title" => "Existing Title", "author" => "Author" } ],
            "total" => 1
          }.to_json
        )
      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [],
            "total" => 0
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!
      assert result.success?

      # ab-old should be pruned since lib-old is no longer configured
      assert_not LibraryItem.exists?(audiobookshelf_id: "ab-old")

      # ab-existing should be kept
      assert LibraryItem.exists?(audiobookshelf_id: "ab-existing")
    end
  end

  test "does not prune cached items written after this run started" do
    # Create library items for a library that is not configured, but synced_at is in the future (written after this run started)
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-newly-added",
      audiobookshelf_id: "ab-new",
      title: "New Library Item",
      author: "Author",
      synced_at: Time.current + 1.minute
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [],
            "total" => 0
          }.to_json
        )
      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [],
            "total" => 0
          }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!
      assert result.success?

      # ab-new should NOT be pruned because it was written after this run started
      assert LibraryItem.exists?(audiobookshelf_id: "ab-new")
    end
  end

  test "skips destructive pruning if library settings change during sync run" do
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-old",
      audiobookshelf_id: "ab-old",
      title: "Old Library Item",
      author: "Author",
      synced_at: 1.day.ago
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:13378/api/libraries/lib-audio/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return do
          # Simulate settings changing mid-run (e.g. user adds a scan library while sync is running)
          SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "lib-new-scan")
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "results" => [], "total" => 0 }.to_json
          }
        end

      stub_request(:get, %r{localhost:13378/api/libraries/lib-ebook/items})
        .with(query: hash_including("limit" => "500", "page" => "0"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "results" => [], "total" => 0 }.to_json
        )

      result = AudiobookshelfLibrarySyncService.new.sync!
      assert result.success?

      # Because settings changed mid-run, destructive pruning of lib-old should be skipped
      assert LibraryItem.exists?(audiobookshelf_id: "ab-old")
    end
  ensure
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "")
  end
end
