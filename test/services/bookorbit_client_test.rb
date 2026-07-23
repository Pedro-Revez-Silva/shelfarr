# frozen_string_literal: true

require "test_helper"
require "timeout"

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

  test "libraries rebuilds cached connection when BookOrbit settings change" do
    VCR.turned_off do
      old_login = stub_request(:post, "http://localhost:3000/api/v1/auth/login")
        .with(body: { username: "admin", password: "secret" }.to_json)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessToken: "old-token" }.to_json
        )
      old_libraries = stub_request(:get, "http://localhost:3000/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer old-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { id: 1, name: "Old Library", folders: [] } ].to_json
        )

      assert_equal "Old Library", BookOrbitClient.libraries.first.name

      SettingsService.set(:bookorbit_url, "http://localhost:4000")

      new_login = stub_request(:post, "http://localhost:4000/api/v1/auth/login")
        .with(body: { username: "admin", password: "secret" }.to_json)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessToken: "new-token" }.to_json
        )
      new_libraries = stub_request(:get, "http://localhost:4000/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer new-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { id: 2, name: "New Library", folders: [] } ].to_json
        )

      assert_equal "New Library", BookOrbitClient.libraries.first.name
      assert_requested old_login, times: 1
      assert_requested old_libraries, times: 1
      assert_requested new_login, times: 1
      assert_requested new_libraries, times: 1
    end
  end

  test "concurrent connection rebuilds cannot publish stale BookOrbit settings" do
    VCR.turned_off do
      old_configuration_read = Queue.new
      release_old_configuration = Queue.new

      stub_request(:post, "http://localhost:3000/api/v1/auth/login")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessToken: "old-token" }.to_json
        )
      stub_request(:get, "http://localhost:3000/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer old-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { id: 1, name: "Old Library", folders: [] } ].to_json
        )
      stub_request(:post, "http://localhost:4000/api/v1/auth/login")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessToken: "new-token" }.to_json
        )
      stub_request(:get, "http://localhost:4000/api/v1/libraries")
        .with(headers: { "Authorization" => "Bearer new-token" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { id: 2, name: "New Library", folders: [] } ].to_json
        )

      original_configuration = BookOrbitClient.method(:current_connection_configuration)
      configuration_reader = lambda do
        configuration = original_configuration.call
        if Thread.current[:bookorbit_old_connection]
          old_configuration_read << true
          release_old_configuration.pop
        end
        configuration
      end

      old_request = nil
      new_request = nil
      BookOrbitClient.stub(:current_connection_configuration, configuration_reader) do
        begin
          old_request = Thread.new do
            Thread.current[:bookorbit_old_connection] = true
            BookOrbitClient.libraries
          end
          Timeout.timeout(2) { old_configuration_read.pop }

          SettingsService.set(:bookorbit_url, "http://localhost:4000")
          new_request = Thread.new { BookOrbitClient.libraries }

          assert_nil new_request.join(0.2), "new connection build should wait for the in-flight rebuild"
          release_old_configuration << true

          assert_equal "Old Library", Timeout.timeout(2) { old_request.value.first.name }
          assert_equal "New Library", Timeout.timeout(2) { new_request.value.first.name }
        ensure
          release_old_configuration << true
          [ old_request, new_request ].compact.each do |thread|
            next if thread.join(2)

            thread.kill
            thread.join
          end
        end
      end

      assert_equal "New Library", BookOrbitClient.libraries.first.name
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

  test "library_items returns empty array on page 0 404 or 410 response" do
    VCR.turned_off do
      stub_login
      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .to_return(status: 404)
      assert_equal [], BookOrbitClient.library_items("42")

      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .to_return(status: 410)
      assert_equal [], BookOrbitClient.library_items("42")
    end
  end

  test "library_items raises Error on later-page 404 response" do
    VCR.turned_off do
      stub_login
      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .with(body: hash_including("pagination" => { "page" => 0, "size" => 200 }))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "items" => Array.new(200) { { "id" => 101, "title" => "a" } },
            "total" => 400,
            "page" => 0,
            "size" => 200
          }.to_json
        )
      stub_request(:post, "http://localhost:3000/api/v1/libraries/42/books")
        .with(body: hash_including("pagination" => { "page" => 1, "size" => 200 }))
        .to_return(status: 404)

      assert_raises BookOrbitClient::Error do
        BookOrbitClient.library_items("42")
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
