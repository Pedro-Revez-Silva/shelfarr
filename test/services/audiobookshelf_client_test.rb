# frozen_string_literal: true

require "test_helper"

class AudiobookshelfClientTest < ActiveSupport::TestCase
  setup do
    AudiobookshelfClient.reset_connection!
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key-12345")
  end

  teardown do
    AudiobookshelfClient.reset_connection!
  end

  test "configured? returns true when properly configured" do
    assert AudiobookshelfClient.configured?
  end

  test "configured? returns false when url is missing" do
    SettingsService.set(:audiobookshelf_url, "")
    assert_not AudiobookshelfClient.configured?
  end

  test "configured? returns false when api_key is missing" do
    SettingsService.set(:audiobookshelf_api_key, "")
    assert_not AudiobookshelfClient.configured?
  end

  test "libraries returns list of libraries" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "libraries" => [
              {
                "id" => "lib-audiobooks-123",
                "name" => "Audiobooks",
                "mediaType" => "book",
                "folders" => [
                  { "id" => "folder1", "fullPath" => "/audiobooks" }
                ]
              },
              {
                "id" => "lib-podcasts-456",
                "name" => "Podcasts",
                "mediaType" => "podcast",
                "folders" => [
                  { "id" => "folder2", "fullPath" => "/podcasts" }
                ]
              }
            ]
          }.to_json
        )

      libraries = AudiobookshelfClient.libraries

      assert_kind_of Array, libraries
      assert_equal 2, libraries.size

      audiobook_lib = libraries.find { |l| l.id == "lib-audiobooks-123" }
      assert_equal "Audiobooks", audiobook_lib.name
      assert audiobook_lib.audiobook_library?
      assert_not audiobook_lib.podcast_library?
      assert_equal [ "/audiobooks" ], audiobook_lib.folder_paths
    end
  end

  test "library returns single library" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "id" => "lib-123",
            "name" => "My Audiobooks",
            "mediaType" => "book",
            "folders" => [
              { "id" => "folder1", "fullPath" => "/media/audiobooks" }
            ]
          }.to_json
        )

      library = AudiobookshelfClient.library("lib-123")

      assert_equal "lib-123", library.id
      assert_equal "My Audiobooks", library.name
      assert_equal [ "/media/audiobooks" ], library.folder_paths
    end
  end

  test "scan_library triggers library scan" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:13378/api/libraries/lib-123/scan")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(status: 200)

      result = AudiobookshelfClient.scan_library("lib-123")
      assert result
    end
  end

  test "library_items returns parsed book items" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123/items?limit=500&page=0")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-item-1",
                "title" => "The Hobbit",
                "isMissing" => false,
                "media" => {
                  "author" => "J.R.R. Tolkien",
                  "metadata" => {
                    "subtitle" => "There and Back Again",
                    "series" => [
                      { "name" => "Middle-earth Universe", "sequence" => "0" }
                    ],
                    "publishedYear" => "1937",
                    "narratorName" => "Andy Serkis",
                    "isbn" => "9780261103283",
                    "language" => "en"
                  }
                }
              },
              {
                "id" => "ab-item-2",
                "media" => {
                  "title" => "Good Omens",
                  "metadata" => {
                    "authors" => [ "Neil Gaiman", "Terry Pratchett" ]
                  }
                }
              }
            ],
            "total" => 2
          }.to_json
        )

      items = AudiobookshelfClient.library_items("lib-123", page_size: 500)

      assert_equal 2, items.size
      assert_equal "ab-item-1", items.first["audiobookshelf_id"]
      assert_equal "The Hobbit", items.first["title"]
      assert_equal "There and Back Again", items.first["subtitle"]
      assert_equal "J.R.R. Tolkien", items.first["author"]
      assert_equal "Andy Serkis", items.first["narrator"]
      assert_equal "Middle-earth Universe", items.first["series"]
      assert_equal "0", items.first["series_position"]
      assert_equal 1937, items.first["published_year"]
      assert_equal "9780261103283", items.first["isbn"]
      assert_equal "en", items.first["language"]
      assert_equal false, items.first["missing"]
      assert_equal "Good Omens", items.last["title"]
      assert_equal "Neil Gaiman, Terry Pratchett", items.last["author"]
    end
  end

  test "library_items extracts rich metadata from media metadata" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123/items?limit=500&page=0")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-item-1",
                "media" => {
                  "metadata" => {
                    "title" => "Project Hail Mary",
                    "subtitle" => "A Novel",
                    "authorName" => "Andy Weir",
                    "narrators" => [ "Ray Porter" ],
                    "series" => [
                      { "series" => { "name" => "Bobiverse-adjacent" }, "sequence" => "1" }
                    ],
                    "publishedDate" => "2021-05-04",
                    "publisher" => "Ballantine Books",
                    "description" => "A lone astronaut must save Earth.",
                    "isbn" => [ "9780593135204", "0593135202" ],
                    "asin" => "B08GB58KD5",
                    "language" => "en"
                  }
                }
              },
              {
                "id" => "ab-item-2",
                "media" => {
                  "metadata" => {
                    "title" => "Good Omens",
                    "authors" => [
                      { "name" => "Neil Gaiman" },
                      { "name" => "Terry Pratchett" }
                    ],
                    "narrators" => [
                      { "name" => "Martin Jarvis" }
                    ]
                  }
                }
              }
            ],
            "total" => 2
          }.to_json
        )

      items = AudiobookshelfClient.library_items("lib-123", page_size: 500)

      assert_equal 2, items.size
      assert_equal "Project Hail Mary", items.first["title"]
      assert_equal "A Novel", items.first["subtitle"]
      assert_equal "Andy Weir", items.first["author"]
      assert_equal "Ray Porter", items.first["narrator"]
      assert_equal "Bobiverse-adjacent", items.first["series"]
      assert_equal "1", items.first["series_position"]
      assert_equal 2021, items.first["published_year"]
      assert_equal "Ballantine Books", items.first["publisher"]
      assert_equal "A lone astronaut must save Earth.", items.first["description"]
      assert_equal "9780593135204", items.first["isbn"]
      assert_equal "B08GB58KD5", items.first["asin"]
      assert_equal "en", items.first["language"]
      assert_equal "Good Omens", items.last["title"]
      assert_equal "Neil Gaiman, Terry Pratchett", items.last["author"]
      assert_equal "Martin Jarvis", items.last["narrator"]
    end
  end

  test "library_items starts pagination at page zero" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123/items?limit=2&page=0")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-item-1",
                "media" => {
                  "metadata" => {
                    "title" => "The Way of Kings Prime",
                    "authorName" => "Brandon Sanderson"
                  }
                }
              },
              {
                "id" => "ab-item-2",
                "media" => {
                  "metadata" => {
                    "title" => "Tress of the Emerald Sea",
                    "authorName" => "Brandon Sanderson"
                  }
                }
              }
            ],
            "total" => 3,
            "page" => 0
          }.to_json
        )

      stub_request(:get, "http://localhost:13378/api/libraries/lib-123/items?limit=2&page=1")
        .with(headers: { "Authorization" => "Bearer test-api-key-12345" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-item-3",
                "media" => {
                  "metadata" => {
                    "title" => "Yumi and the Nightmare Painter",
                    "authorName" => "Brandon Sanderson"
                  }
                }
              }
            ],
            "total" => 3,
            "page" => 1
          }.to_json
        )

      items = AudiobookshelfClient.library_items("lib-123", page_size: 2)

      assert_equal 3, items.size
      assert_equal "ab-item-1", items.first["audiobookshelf_id"]
      assert_equal "ab-item-3", items.last["audiobookshelf_id"]
    end
  end

  test "test_connection returns true when libraries exist" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "libraries" => [ { "id" => "lib-1", "name" => "Test", "mediaType" => "book", "folders" => [] } ] }.to_json
        )

      assert AudiobookshelfClient.test_connection
    end
  end

  test "test_connection returns false on authentication error" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(status: 401)

      assert_not AudiobookshelfClient.test_connection
    end
  end

  test "test_connection returns false on connection error" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_timeout

      assert_not AudiobookshelfClient.test_connection
    end
  end

  test "raises NotConfiguredError when not configured" do
    SettingsService.set(:audiobookshelf_url, "")

    assert_raises AudiobookshelfClient::NotConfiguredError do
      AudiobookshelfClient.libraries
    end
  end

  test "raises AuthenticationError on 401 response" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(status: 401)

      assert_raises AudiobookshelfClient::AuthenticationError do
        AudiobookshelfClient.libraries
      end
    end
  end

  test "raises Error on 404 response" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/nonexistent")
        .to_return(status: 404)

      assert_raises AudiobookshelfClient::Error do
        AudiobookshelfClient.library("nonexistent")
      end
    end
  end

  test "raises ConnectionError on timeout" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_timeout

      assert_raises AudiobookshelfClient::ConnectionError do
        AudiobookshelfClient.libraries
      end
    end
  end

  test "raises ConnectionError on malformed url" do
    SettingsService.set(:audiobookshelf_url, "audiobookshelf:13378")

    assert_raises AudiobookshelfClient::ConnectionError do
      AudiobookshelfClient.libraries
    end
  end

  # SSL error handling tests
  test "test_connection returns false on SSL error" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      assert_not AudiobookshelfClient.test_connection
    end
  end

  test "raises ConnectionError on SSL error" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      assert_raises AudiobookshelfClient::ConnectionError do
        AudiobookshelfClient.libraries
      end
    end
  end

  test "test_connection returns false on malformed url" do
    SettingsService.set(:audiobookshelf_url, "audiobookshelf:13378")

    assert_not AudiobookshelfClient.test_connection
  end
end
