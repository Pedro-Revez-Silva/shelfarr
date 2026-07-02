# frozen_string_literal: true

require "test_helper"

class GrimmoryClientTest < ActiveSupport::TestCase
  setup do
    LibraryPlatformClient.reset_connections!
    SettingsService.set(:library_platform, "grimmory")
    SettingsService.set(:grimmory_url, "http://localhost:5173")
    SettingsService.set(:grimmory_username, "admin")
    SettingsService.set(:grimmory_password, "secret")
  end

  teardown do
    LibraryPlatformClient.reset_connections!
    SettingsService.set(:library_platform, "audiobookshelf")
  end

  test "configured? returns true when Grimmory is selected and credentials are present" do
    assert GrimmoryClient.configured?
    assert LibraryPlatformClient.configured?
    assert_equal "Grimmory", LibraryPlatformClient.display_name
  end

  test "libraries logs in and returns Grimmory libraries" do
    VCR.turned_off do
      stub_login
      stub_request(:get, "http://localhost:5173/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer grimmory-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "id" => "lib-1",
              "name" => "Ebooks",
              "paths" => [ { "id" => "path-1", "path" => "/books/ebooks" } ],
              "allowedFormats" => [ "EPUB", "CBX" ]
            },
            {
              "id" => "lib-2",
              "name" => "Audiobooks",
              "paths" => [ { "id" => "path-2", "path" => "/books/audiobooks" } ],
              "allowedFormats" => [ "AUDIOBOOK" ]
            }
          ].to_json
        )

      libraries = LibraryPlatformClient.libraries

      assert_equal 2, libraries.size
      assert_equal "lib-1", libraries.first.id
      assert_equal "Ebooks", libraries.first.name
      assert_equal [ "/books/ebooks" ], libraries.first.folder_paths
      assert_equal "ebook", libraries.first.media_type
      assert libraries.first.audiobook_library?
      assert_equal "audiobook", libraries.second.media_type
    end
  end

  test "library_items maps Grimmory books into Shelfarr library item attributes" do
    VCR.turned_off do
      stub_login
      stub_request(:get, "http://localhost:5173/api/v1/libraries/lib-1/book")
        .with(headers: { "Authorization" => "Bearer grimmory-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "id" => "book-1",
              "status" => "present",
              "title" => "The Left Hand of Darkness",
              "subtitle" => "A Novel",
              "authors" => [ { "name" => "Ursula K. Le Guin" } ],
              "narrators" => [ "George Guidall" ],
              "series" => { "name" => "Hainish Cycle", "position" => 4 },
              "publisher" => { "name" => "Ace" },
              "language" => "en",
              "description" => "A winter planet story.",
              "isbn13" => "9780441478125",
              "publishedDate" => "1969-03-01"
            },
            {
              "id" => "book-2",
              "status" => "missing",
              "title" => "Missing Book",
              "authors" => []
            }
          ].to_json
        )

      items = LibraryPlatformClient.library_items("lib-1")

      assert_equal 2, items.size
      assert_equal "book-1", items.first["audiobookshelf_id"]
      assert_equal "The Left Hand of Darkness", items.first["title"]
      assert_equal "A Novel", items.first["subtitle"]
      assert_equal "Ursula K. Le Guin", items.first["author"]
      assert_equal "George Guidall", items.first["narrator"]
      assert_equal "Hainish Cycle", items.first["series"]
      assert_equal "4", items.first["series_position"]
      assert_equal "Ace", items.first["publisher"]
      assert_equal "en", items.first["language"]
      assert_equal "A winter planet story.", items.first["description"]
      assert_equal "9780441478125", items.first["isbn"]
      assert_equal 1969, items.first["published_year"]
      assert_equal false, items.first["missing"]
      assert_equal true, items.last["missing"]
    end
  end

  test "library_items maps Grimmory native metadata fields" do
    VCR.turned_off do
      stub_login
      stub_request(:get, "http://localhost:5173/api/v1/libraries/lib-1/book")
        .with(headers: { "Authorization" => "Bearer grimmory-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "id" => "book-1",
              "title" => "Caliban's War",
              "metadata" => {
                "authors" => [ "James S. A. Corey" ],
                "seriesName" => "The Expanse",
                "seriesNumber" => 2.0,
                "publishedDate" => "2012-06-26"
              }
            }
          ].to_json
        )

      item = LibraryPlatformClient.library_items("lib-1").first

      assert_equal "James S. A. Corey", item["author"]
      assert_equal "The Expanse", item["series"]
      assert_equal "2.0", item["series_position"]
      assert_equal 2012, item["published_year"]
    end
  end

  test "scan_library calls Grimmory refresh endpoint" do
    VCR.turned_off do
      stub_login
      stub_request(:put, "http://localhost:5173/api/v1/libraries/lib-1/refresh")
        .with(headers: { "Authorization" => "Bearer grimmory-token" })
        .to_return(status: 204)

      assert LibraryPlatformClient.scan_library("lib-1")
    end
  end

  test "facade translates Grimmory authentication errors" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:5173/api/v1/auth/login")
        .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: {}.to_json)

      assert_raises LibraryPlatformClient::AuthenticationError do
        LibraryPlatformClient.libraries
      end
    end
  end

  test "relogs in once when cached Grimmory token is rejected" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:5173/api/v1/auth/login")
        .with(body: { username: "admin", password: "secret" }.to_json)
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { accessToken: "expired-token" }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { accessToken: "fresh-token" }.to_json
          }
        )
      stub_request(:get, "http://localhost:5173/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer expired-token" })
        .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: {}.to_json)
      stub_request(:get, "http://localhost:5173/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer fresh-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "id" => "lib-1", "name" => "Ebooks", "paths" => [], "allowedFormats" => [ "epub" ] } ].to_json
        )

      libraries = LibraryPlatformClient.libraries

      assert_equal [ "lib-1" ], libraries.map(&:id)
    end
  end

  private

  def stub_login
    stub_request(:post, "http://localhost:5173/api/v1/auth/login")
      .with(body: { username: "admin", password: "secret" }.to_json)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { accessToken: "grimmory-token" }.to_json
      )
  end
end
