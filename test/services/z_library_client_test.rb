# frozen_string_literal: true

require "test_helper"

class ZLibraryClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")
    ZLibraryClient.reset_auth_cache!
  end

  teardown do
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    ZLibraryClient.reset_auth_cache!
  end

  test "configured? returns true when both email and password set" do
    assert ZLibraryClient.configured?
  end

  test "configured? returns false when email missing" do
    SettingsService.set(:zlibrary_email, "")
    assert_not ZLibraryClient.configured?
  end

  test "configured? returns false when password missing" do
    SettingsService.set(:zlibrary_password, "")
    assert_not ZLibraryClient.configured?
  end

  test "login succeeds and caches auth" do
    VCR.turned_off do
      stub_zlibrary_login_success

      auth = ZLibraryClient.send(:login)

      assert_equal "12345", auth[:remix_userid]
      assert_equal "abcdef123456", auth[:remix_userkey]
      assert_equal "z-library.bz", auth[:domain]
    end
  end

  test "login tries next domain on failure" do
    VCR.turned_off do
      stub_request(:post, "https://z-library.bz/eapi/user/login")
        .to_return(status: 500, body: "Server Error")
      stub_request(:post, "https://1lib.sk/eapi/user/login")
        .to_return(
          status: 200,
          body: { success: 1, user: { id: "12345", remix_userkey: "abcdef123456" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      auth = ZLibraryClient.send(:login)

      assert_equal "1lib.sk", auth[:domain]
    end
  end

  test "login returns nil when all domains fail" do
    VCR.turned_off do
      stub_zlibrary_login_all_fail

      auth = ZLibraryClient.send(:login)

      assert_nil auth
    end
  end

  test "login caches auth for subsequent calls" do
    VCR.turned_off do
      stub_zlibrary_login_success

      auth1 = ZLibraryClient.send(:login)
      auth2 = ZLibraryClient.send(:login)

      assert_equal auth1, auth2
      assert_requested(:post, "https://z-library.bz/eapi/user/login", times: 1)
    end
  end

  test "search returns results from eAPI" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_zlibrary_search_success

      results = ZLibraryClient.search("Test Book")

      assert_equal 1, results.size
      result = results.first
      assert_equal "999", result.id
      assert_equal "deadbeef", result.hash
      assert_equal "Test Book Title", result.title
      assert_equal "Test Author", result.author
      assert_equal "epub", result.file_type
      assert_equal 5452595, result.file_size
      assert_equal 2023, result.year
      assert_equal "english", result.language
    end
  end

  test "search returns empty array when no results" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.bz/eapi/book/search")
        .to_return(
          status: 200,
          body: { success: 1, books: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = ZLibraryClient.search("Nonexistent Book")

      assert_equal [], results
    end
  end

  test "search raises NotConfiguredError when not configured" do
    SettingsService.set(:zlibrary_email, "")

    assert_raises ZLibraryClient::NotConfiguredError do
      ZLibraryClient.search("Test")
    end
  end

  test "search raises AuthenticationError when login fails" do
    VCR.turned_off do
      stub_zlibrary_login_all_fail

      assert_raises ZLibraryClient::AuthenticationError do
        ZLibraryClient.search("Test")
      end
    end
  end

  test "search passes file type extensions" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.bz/eapi/book/search")
        .with { |req| req.body.include?("extensions%5B%5D=epub") }
        .to_return(
          status: 200,
          body: { success: 1, books: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      ZLibraryClient.search("Test", file_types: %w[epub])

      assert_requested(:post, "https://z-library.bz/eapi/book/search")
    end
  end

  test "get_download_url returns direct URL from eAPI" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_zlibrary_download_success

      url = ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")

      assert_equal "https://download.z-library.bz/dl/book999/file.epub", url
    end
  end

  test "get_download_url raises Error when no download link" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:get, "https://z-library.bz/eapi/book/999/deadbeef/file")
        .to_return(
          status: 200,
          body: { success: 0, error: "Book not found" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_raises ZLibraryClient::Error do
        ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
      end
    end
  end

  test "get_download_url raises NotConfiguredError when not configured" do
    SettingsService.set(:zlibrary_email, "")

    assert_raises ZLibraryClient::NotConfiguredError do
      ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
    end
  end

  private

  def stub_zlibrary_login_success
    stub_request(:post, "https://z-library.bz/eapi/user/login")
      .to_return(
        status: 200,
        body: {
          success: 1,
          user: { id: "12345", remix_userkey: "abcdef123456" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_login_all_fail
    %w[z-library.bz 1lib.sk z-lib.fm z-lib.sk].each do |domain|
      stub_request(:post, "https://#{domain}/eapi/user/login")
        .to_return(status: 500, body: "Server Error")
    end
  end

  def stub_zlibrary_download_success
    stub_request(:get, "https://z-library.bz/eapi/book/999/deadbeef/file")
      .to_return(
        status: 200,
        body: {
          success: 1,
          file: {
            description: "Test Book Title",
            extension: "epub",
            downloadLink: "https://download.z-library.bz/dl/book999/file.epub"
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_search_success
    stub_request(:post, "https://z-library.bz/eapi/book/search")
      .to_return(
        status: 200,
        body: {
          success: 1,
          books: [
            {
              id: 999,
              hash: "deadbeef",
              name: "Test Book Title",
              author: "Test Author",
              year: "2023",
              extension: "epub",
              filesize: "5452595",
              language: "english"
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
