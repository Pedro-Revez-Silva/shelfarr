# frozen_string_literal: true

require "test_helper"

class ZLibraryClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")
    ZLibraryClient.reset_connection!
  end

  teardown do
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    ZLibraryClient.reset_connection!
  end

  test "configured? requires enable flag and credentials" do
    assert ZLibraryClient.configured?

    SettingsService.set(:zlibrary_enabled, false)
    assert_not ZLibraryClient.configured?
  end

  test "test_connection returns true when login succeeds" do
    VCR.turned_off do
      stub_zlibrary_login_success
      assert ZLibraryClient.test_connection
    end
  end

  test "search returns parsed results" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 200,
          body: {
            success: 1,
            books: [
              {
                id: 999,
                hash: "deadbeef",
                name: "Test Book",
                author: "Author",
                year: "2024",
                extension: "epub",
                filesize: "12345",
                language: "English"
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = ZLibraryClient.search("Test Book", language: "english")

      assert_equal 1, results.size
      assert_equal "999", results.first.id
      assert_equal "en", results.first.language
    end
  end

  test "login tries configured urls until one succeeds" do
    SettingsService.set(:zlibrary_url, "https://offline.example\nhttps://z-library.sk")

    VCR.turned_off do
      stub_request(:post, "https://offline.example/eapi/user/login")
        .to_raise(Faraday::SSLError.new("certificate verify failed"))
      stub_zlibrary_login_success

      auth = ZLibraryClient.send(:login)

      assert_equal "z-library.sk", auth[:domain]
      assert_requested(:post, "https://offline.example/eapi/user/login")
      assert_requested(:post, "https://z-library.sk/eapi/user/login")
    end
  end

  test "search uses the domain that accepted login" do
    SettingsService.set(:zlibrary_url, "https://offline.example, https://z-library.sk")

    VCR.turned_off do
      stub_request(:post, "https://offline.example/eapi/user/login")
        .to_return(status: 503, body: "unavailable")
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 200,
          body: { success: 1, books: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      ZLibraryClient.search("Test Book")

      assert_requested(:post, "https://z-library.sk/eapi/book/search")
      assert_not_requested(:post, "https://offline.example/eapi/book/search")
    end
  end

  test "search retries configured urls when cached domain fails" do
    SettingsService.set(:zlibrary_url, "https://z-library.sk\nhttps://z-library.bz")

    VCR.turned_off do
      stub_request(:post, "https://z-library.sk/eapi/user/login")
        .with(body: "email=reader%40example.com&password=secret")
        .to_return(
          status: 200,
          body: { success: 1, user: { id: "12345", remix_userkey: "abc123" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        ).then
        .to_return(status: 503, body: "unavailable")
      stub_zlibrary_login_success("z-library.bz")
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(status: 503, body: "unavailable")
      stub_request(:post, "https://z-library.bz/eapi/book/search")
        .to_return(
          status: 200,
          body: { success: 1, books: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_equal "z-library.sk", ZLibraryClient.send(:login)[:domain]
      ZLibraryClient.search("Test Book")

      assert_requested(:post, "https://z-library.sk/eapi/book/search")
      assert_requested(:post, "https://z-library.bz/eapi/book/search")
    end
  end

  test "search retries alternate eAPI domain before HTML fallback" do
    SettingsService.set(:zlibrary_url, "https://z-library.sk\nhttps://z-library.bz")

    VCR.turned_off do
      stub_zlibrary_login_success
      stub_zlibrary_login_success("z-library.bz")

      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 400,
          body: { success: 0, error: "Some errors occured." }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      bz_search = stub_request(:post, "https://z-library.bz/eapi/book/search")
        .to_return(
          status: 200,
          body: {
            success: 1,
            books: [
              {
                id: 123,
                hash: "feedbeef",
                name: "Recovered via API",
                author: "Author",
                extension: "epub"
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = ZLibraryClient.search("Test Book")

      assert_equal "123", results.first.id
      assert_equal "Recovered via API", results.first.title
      assert_requested(bz_search)
      assert_not_requested(:get, %r{https://z-library\.sk/s/})
    end
  end

  test "search raises AuthenticationError when login fails" do
    VCR.turned_off do
      stub_zlibrary_login_failure

      assert_raises ZLibraryClient::AuthenticationError do
        ZLibraryClient.search("Test")
      end
    end
  end

  test "search passes language filter through request body" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .with { |request| request.body.include?("languages%5B%5D=english") }
        .to_return(
          status: 200,
          body: { success: 1, books: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      ZLibraryClient.search("Test", language: "english")

      assert_requested(:post, "https://z-library.sk/eapi/book/search")
    end
  end

  test "search falls back to HTML results when eAPI returns 400" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 400,
          body: { success: 0, error: "Some errors occured." }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      html_stub = stub_request(:get, "https://z-library.sk/s/Test%20Book?extensions%5B%5D=EPUB&extensions%5B%5D=PDF&languages%5B%5D=english")
        .with(headers: { "Cookie" => "remix_userid=12345; remix_userkey=abc123" })
        .to_return(
          status: 200,
          body: zlibrary_search_html,
          headers: { "Content-Type" => "text/html" }
        )

      results = ZLibraryClient.search("Test Book", language: "english")

      assert_equal 1, results.size
      assert_equal "999", results.first.id
      assert_equal "deadbeef", results.first.hash
      assert_equal "Test Book", results.first.title
      assert_equal "Author One, Author Two", results.first.author
      assert_equal 2024, results.first.year
      assert_equal "epub", results.first.file_type
      assert_equal 1_572_864, results.first.file_size
      assert_equal "en", results.first.language
      assert_requested(html_stub)
    end
  end

  test "search falls back to HTML results when eAPI returns HTML" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 200,
          body: "<!doctype html><html><body>Unavailable</body></html>",
          headers: { "Content-Type" => "text/html" }
        )

      html_stub = stub_request(:get, "https://z-library.sk/s/Test%20Book?extensions%5B%5D=EPUB&extensions%5B%5D=PDF")
        .to_return(
          status: 200,
          body: zlibrary_search_html,
          headers: { "Content-Type" => "text/html" }
        )

      assert_equal "999", ZLibraryClient.search("Test Book").first.id
      assert_requested(html_stub)
    end
  end

  test "search falls back to HTML results when eAPI returns generic error payload" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:post, "https://z-library.sk/eapi/book/search")
        .to_return(
          status: 200,
          body: { success: 0, error: "Some errors occured. Error identificator: ." }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://z-library.sk/s/Test%20Book?extensions%5B%5D=EPUB&extensions%5B%5D=PDF")
        .to_return(
          status: 200,
          body: zlibrary_search_html,
          headers: { "Content-Type" => "text/html" }
        )

      assert_equal "999", ZLibraryClient.search("Test Book").first.id
    end
  end

  test "get_download_url validates returned URL scheme" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:get, "https://z-library.sk/eapi/book/999/deadbeef/file")
        .to_return(
          status: 200,
          body: {
            success: 1,
            file: { downloadLink: "file:///tmp/book.epub" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_raises ZLibraryClient::Error do
        ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
      end
    end
  end

  test "get_download_url falls back to HTML book page when eAPI returns 400" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:get, "https://z-library.sk/eapi/book/999/deadbeef/file")
        .to_return(
          status: 400,
          body: { success: 0, error: "Some errors occured." }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      html_stub = stub_request(:get, "https://z-library.sk/book/999/deadbeef")
        .with(headers: { "Cookie" => "remix_userid=12345; remix_userkey=abc123" })
        .to_return(
          status: 200,
          body: '<html><a class="btn btn-default addDownloadedBook" href="/dl/999/deadbeef/book.epub">Download</a></html>',
          headers: { "Content-Type" => "text/html" }
        )

      assert_equal "https://z-library.sk/dl/999/deadbeef/book.epub", ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
      assert_requested(html_stub)
    end
  end

  test "get_download_url falls back to HTML book page when eAPI returns HTML" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:get, "https://z-library.sk/eapi/book/999/deadbeef/file")
        .to_return(
          status: 200,
          body: "<html><body>Unavailable</body></html>",
          headers: { "Content-Type" => "text/html" }
        )

      html_stub = stub_request(:get, "https://z-library.sk/book/999/deadbeef")
        .with(headers: { "Cookie" => "remix_userid=12345; remix_userkey=abc123" })
        .to_return(
          status: 200,
          body: '<html><a class="btn btn-default addDownloadedBook" href="/dl/999/deadbeef/book.epub">Download</a></html>',
          headers: { "Content-Type" => "text/html" }
        )

      assert_equal "https://z-library.sk/dl/999/deadbeef/book.epub", ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
      assert_requested(html_stub)
    end
  end

  test "get_download_url retries alternate eAPI domain before HTML fallback" do
    SettingsService.set(:zlibrary_url, "https://z-library.sk\nhttps://z-library.bz")

    VCR.turned_off do
      stub_zlibrary_login_success
      stub_zlibrary_login_success("z-library.bz")

      stub_request(:get, "https://z-library.sk/eapi/book/999/deadbeef/file")
        .to_return(
          status: 400,
          body: { success: 0, error: "Some errors occured." }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      bz_lookup = stub_request(:get, "https://z-library.bz/eapi/book/999/deadbeef/file")
        .to_return(
          status: 200,
          body: {
            success: 1,
            file: { downloadLink: "https://download.z-library.bz/books/test-book.epub" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_equal "https://download.z-library.bz/books/test-book.epub", ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
      assert_requested(bz_lookup)
      assert_not_requested(:get, "https://z-library.sk/book/999/deadbeef")
    end
  end

  test "get_download_url allows hosts outside configured family" do
    VCR.turned_off do
      stub_zlibrary_login_success
      stub_request(:get, "https://z-library.sk/eapi/book/999/deadbeef/file")
        .to_return(
          status: 200,
          body: {
            success: 1,
            file: { downloadLink: "https://evil.example/book.epub" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_equal "https://evil.example/book.epub", ZLibraryClient.get_download_url(id: "999", hash: "deadbeef")
    end
  end

  test "login cache is invalidated when credentials change" do
    VCR.turned_off do
      stub_zlibrary_login_success

      first_auth = ZLibraryClient.send(:login)
      SettingsService.set(:zlibrary_password, "new-secret")
      stub_request(:post, "https://z-library.sk/eapi/user/login")
        .with(body: "email=reader%40example.com&password=new-secret")
        .to_return(
          status: 200,
          body: { success: 1, user: { id: "54321", remix_userkey: "updated-key" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      second_auth = ZLibraryClient.send(:login)

      refute_equal first_auth, second_auth
      assert_equal "54321", second_auth[:remix_userid]
    end
  end

  test "configured? requires a valid url" do
    SettingsService.set(:zlibrary_url, "")
    assert_not ZLibraryClient.configured?
  end

  test "test_connection returns false for invalid url" do
    SettingsService.set(:zlibrary_url, "not-a-url")
    assert_not ZLibraryClient.test_connection
  end

  test "test_connection returns false when url includes a path" do
    SettingsService.set(:zlibrary_url, "https://z-library.sk/login")
    assert_not ZLibraryClient.test_connection
  end

  test "test_connection returns false when any configured url is invalid" do
    SettingsService.set(:zlibrary_url, "https://z-library.sk\nnot-a-url")

    assert_not ZLibraryClient.test_connection
  end

  private

  def stub_zlibrary_login_success(domain = "z-library.sk")
    stub_request(:post, "https://#{domain}/eapi/user/login")
      .with(body: "email=reader%40example.com&password=secret")
      .to_return(
        status: 200,
        body: { success: 1, user: { id: "12345", remix_userkey: "abc123" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_login_failure
    stub_request(:post, "https://z-library.sk/eapi/user/login")
      .to_return(status: 500, body: "server error")
  end

  def zlibrary_search_html
    <<~HTML
      <html>
        <div id="searchResultBox">
          <div class="book-item">
            <z-bookcard id="999"
                        href="/book/999/deadbeef/test-book"
                        year="2024"
                        language="English"
                        extension="EPUB"
                        filesize="1.5 MB">
              <div slot="title">Test Book</div>
              <div slot="author">Author One; Author Two</div>
            </z-bookcard>
          </div>
        </div>
      </html>
    HTML
  end
end
