# frozen_string_literal: true

require "test_helper"

class BookOrbitClientTest < ActiveSupport::TestCase
  setup do
    LibraryPlatformClient.reset_connections!
    SettingsService.set(:library_platform, "bookorbit")
    SettingsService.set(:bookorbit_url, "http://localhost:3000")
    SettingsService.set(:bookorbit_username, "admin")
    SettingsService.set(:bookorbit_password, "secret")
  end

  teardown do
    LibraryPlatformClient.reset_connections!
    SettingsService.set(:library_platform, "audiobookshelf")
  end

  test "configured? returns true when BookOrbit is selected and credentials are present" do
    assert BookOrbitClient.configured?
    assert LibraryPlatformClient.configured?
    assert_equal "BookOrbit", LibraryPlatformClient.display_name
  end

  test "libraries logs in and returns BookOrbit libraries" do
    VCR.turned_off do
      stub_login
      stub_request(:get, "http://localhost:3000/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer bookorbit-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "id" => 42,
              "name" => "Kobo Books",
              "folders" => [ { "id" => 7, "path" => "/books/kobo" } ]
            }
          ].to_json
        )

      libraries = LibraryPlatformClient.libraries

      assert_equal 1, libraries.size
      assert_equal "42", libraries.first.id
      assert_equal "Kobo Books", libraries.first.name
      assert_equal [ "/books/kobo" ], libraries.first.folder_paths
      assert libraries.first.audiobook_library?
    end
  end

  test "library_items maps BookOrbit book cards into Shelfarr library item attributes" do
    VCR.turned_off do
      stub_login
      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .with(
          headers: { "Authorization" => "Bearer bookorbit-token" },
          body: hash_including(
            "sort" => [],
            "collapseSeries" => false,
            "pagination" => { "page" => 0, "size" => 200 }
          )
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "items" => [
              {
                "id" => 101,
                "status" => "present",
                "title" => "The Left Hand of Darkness",
                "subtitle" => "A Novel",
                "authors" => [ "Ursula K. Le Guin" ],
                "narrators" => [ "George Guidall" ],
                "seriesName" => "Hainish Cycle",
                "seriesIndex" => 4,
                "publisher" => "Ace",
                "language" => "en",
                "isbn13" => "9780441478125",
                "publishedYear" => 1969
              },
              {
                "id" => 102,
                "status" => "missing",
                "title" => "Missing Book",
                "authors" => []
              }
            ],
            "total" => 2,
            "page" => 0,
            "size" => 200
          }.to_json
        )

      items = LibraryPlatformClient.library_items("42")

      assert_equal 2, items.size
      assert_equal "101", items.first["audiobookshelf_id"]
      assert_equal "The Left Hand of Darkness", items.first["title"]
      assert_equal "A Novel", items.first["subtitle"]
      assert_equal "Ursula K. Le Guin", items.first["author"]
      assert_equal "George Guidall", items.first["narrator"]
      assert_equal "Hainish Cycle", items.first["series"]
      assert_equal "4", items.first["series_position"]
      assert_equal "9780441478125", items.first["isbn"]
      assert_equal 1969, items.first["published_year"]
      assert_equal false, items.first["missing"]
      assert_equal true, items.last["missing"]
    end
  end

  test "scan_library calls BookOrbit scanner endpoint" do
    VCR.turned_off do
      stub_login
      stub_request(:post, "http://localhost:3000/api/v1/scanner/libraries/42/scan")
        .with(headers: { "Authorization" => "Bearer bookorbit-token" })
        .to_return(status: 202, headers: { "Content-Type" => "application/json" }, body: {}.to_json)

      assert LibraryPlatformClient.scan_library("42")
    end
  end

  test "facade translates BookOrbit authentication errors" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:3000/api/v1/auth/login")
        .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: {}.to_json)

      assert_raises LibraryPlatformClient::AuthenticationError do
        LibraryPlatformClient.libraries
      end
    end
  end

  private

  def stub_login
    stub_request(:post, "http://localhost:3000/api/v1/auth/login")
      .with(body: { username: "admin", password: "secret" }.to_json)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { accessToken: "bookorbit-token" }.to_json
      )
  end
end
