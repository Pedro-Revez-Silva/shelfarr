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
end
