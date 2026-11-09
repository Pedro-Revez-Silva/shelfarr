# frozen_string_literal: true

require "test_helper"

class LibrivoxClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:librivox_enabled, true)
    SettingsService.set(:librivox_url, "https://librivox.org")
    SettingsService.set(:librivox_search_limit, 10)
    LibrivoxClient.reset_connection!
  end

  teardown do
    SettingsService.set(:librivox_enabled, false)
    SettingsService.set(:librivox_url, "https://librivox.org")
    SettingsService.set(:librivox_search_limit, 20)
    LibrivoxClient.reset_connection!
  end

  test "search raises when disabled" do
    SettingsService.set(:librivox_enabled, false)

    assert_raises LibrivoxClient::NotConfiguredError do
      LibrivoxClient.search(title: "Pride and Prejudice")
    end
  end

  test "search returns audiobook results" do
    stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including(
        "format" => "json",
        "extended" => "1",
        "coverart" => "1",
        "limit" => "10",
        "title" => "Pride and Prejudice"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          books: [
            {
              id: "253",
              title: "Pride and Prejudice",
              language: "English",
              copyright_year: "1813",
              url_zip_file: "https://archive.org/compress/pride_and_prejudice_librivox/formats=64KBPS MP3",
              url_librivox: "https://librivox.org/pride-and-prejudice-by-jane-austen/",
              totaltime: "13:06:44",
              authors: [
                { first_name: "Jane", last_name: "Austen" }
              ]
            }
          ]
        }.to_json
      )

    results = LibrivoxClient.search(title: "Pride and Prejudice", author: "Jane Austen", language: "en")

    assert_equal 1, results.size
    result = results.first
    assert_equal "253", result.id
    assert_equal "Pride and Prejudice", result.title
    assert_equal "Jane Austen", result.author
    assert_equal "en", result.language
    assert_equal "audiobook zip", result.file_type
    assert_equal "https://archive.org/compress/pride_and_prejudice_librivox/formats=64KBPS%20MP3", result.download_url
    assert result.downloadable?
  end

  test "search filters mismatched languages" do
    stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including(
        "format" => "json",
        "extended" => "1",
        "coverart" => "1",
        "limit" => "10",
        "title" => "Le Livre"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          books: [
            {
              id: "1",
              title: "Le Livre",
              language: "French",
              url_zip_file: "https://archive.org/compress/le_livre/formats=64KBPS%20MP3"
            }
          ]
        }.to_json
      )

    assert_empty LibrivoxClient.search(title: "Le Livre", language: "en")
  end

  test "test_connection returns false on connection failure" do
    stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including(
        "format" => "json",
        "extended" => "1",
        "coverart" => "1",
        "limit" => "1"
      ))
      .to_raise(Faraday::ConnectionFailed.new("offline"))

    assert RemoteResult.failed?(LibrivoxClient.test_connection)
  end

  test "search returns empty array when LibriVox reports no audiobooks" do
    stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including(
        "format" => "json",
        "extended" => "1",
        "coverart" => "1",
        "limit" => "10",
        "title" => "Not A Real Book"
      ))
      .to_return(
        status: 404,
        headers: { "Content-Type" => "application/json" },
        body: { error: "Audiobooks could not be found" }.to_json
      )

    assert_empty LibrivoxClient.search(title: "Not A Real Book")
  end

  test "search retries missing titles without one leading English article" do
    {
      "A Modest Proposal" => "Modest Proposal",
      "An Ideal Husband" => "Ideal Husband",
      "The Time Machine" => "Time Machine",
      "the Time Machine" => "Time Machine"
    }.each do |title, alternative|
      original = stub_title_search(title, status: 404, limit: 3)
      fallback = stub_title_search(alternative, books: [ audiobook(alternative) ], limit: 3)

      results = LibrivoxClient.search(title: title, language: "en", limit: 3)

      assert_equal [ "177" ], results.map(&:id)
      assert_requested original, times: 1
      assert_requested fallback, times: 1
      WebMock.reset!
    end
  end

  test "search keeps an exact title result without trying an alternative" do
    original = stub_title_search("The Time Machine", books: [ audiobook("The Time Machine") ])

    assert_equal [ "177" ], LibrivoxClient.search(title: "The Time Machine").map(&:id)
    assert_requested original, times: 1
    assert_not_requested :get, "https://librivox.org/api/feed/audiobooks/", query: hash_including("title" => "Time Machine")
  end

  test "search also retries an empty successful response" do
    original = stub_title_search("A Modest Proposal")
    fallback = stub_title_search("Modest Proposal", books: [ audiobook("Modest Proposal") ])

    assert_equal [ "177" ], LibrivoxClient.search(title: "A Modest Proposal").map(&:id)
    assert_requested original, times: 1
    assert_requested fallback, times: 1
  end

  test "search stops after one article alternative also returns no books" do
    original = stub_title_search("The The Book", status: 404)
    fallback = stub_title_search("The Book", status: 404)

    assert_empty LibrivoxClient.search(title: "The The Book")
    assert_requested original, times: 1
    assert_requested fallback, times: 1
    assert_not_requested :get, "https://librivox.org/api/feed/audiobooks/", query: hash_including("title" => "Book")
  end

  test "search does not strip parts of words or an entire title" do
    [ "Theodore", "Another Book", "The", "A" ].each do |title|
      original = stub_title_search(title, status: 404)

      assert_empty LibrivoxClient.search(title: title)
      assert_requested original, times: 1
      WebMock.reset!
    end
  end

  test "article alternatives keep the requested language filter" do
    original = stub_title_search("The Book", status: 404)
    fallback = stub_title_search("Book", books: [ audiobook("Book").merge(language: "French") ])

    assert_empty LibrivoxClient.search(title: "The Book", language: "en")
    assert_requested original, times: 1
    assert_requested fallback, times: 1
  end

  test "search does not disguise an upstream error as an article retry" do
    original = stub_title_search("The Time Machine", status: 500)

    assert_raises(LibrivoxClient::ConnectionError) { LibrivoxClient.search(title: "The Time Machine") }
    assert_requested original, times: 1
    assert_not_requested :get, "https://librivox.org/api/feed/audiobooks/", query: hash_including("title" => "Time Machine")
  end

  test "search does not retry a connection failure with a different title" do
    original = stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including("title" => "The Time Machine"))
      .to_raise(Faraday::TimeoutError.new("offline"))

    assert_raises(LibrivoxClient::ConnectionError) { LibrivoxClient.search(title: "The Time Machine") }
    assert_requested original, times: 1
    assert_not_requested :get, "https://librivox.org/api/feed/audiobooks/", query: hash_including("title" => "Time Machine")
  end

  # The jobs process never sees the web process's reset_connection!.
  test "search uses the corrected LibriVox URL without resetting the connection" do
    SettingsService.set(:librivox_url, "https://old-librivox.example")
    LibrivoxClient.reset_connection!

    stub_request(:get, "https://old-librivox.example/api/feed/audiobooks/")
      .with(query: hash_including("title" => "Pride"))
      .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "{}")
      .times(1)

    assert_empty LibrivoxClient.search(title: "Pride")

    SettingsService.set(:librivox_url, "https://new-librivox.example")

    corrected = stub_request(:get, "https://new-librivox.example/api/feed/audiobooks/")
      .with(query: hash_including("title" => "Pride"))
      .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "{}")

    results = LibrivoxClient.search(title: "Pride")
    assert_requested corrected, times: 1
    assert_empty results
    assert_not_requested :get, %r{old-librivox\.example/api/feed/audiobooks/}, times: 2
  end

  # The jobs process never sees the web process's reset_connection!.
  test "search drops the cached connection after the LibriVox URL is removed" do
    SettingsService.set(:librivox_url, "https://old-librivox.example")
    LibrivoxClient.reset_connection!

    stub_request(:get, "https://old-librivox.example/api/feed/audiobooks/")
      .with(query: hash_including("title" => "Pride"))
      .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: "{}")

    assert_empty LibrivoxClient.search(title: "Pride")

    SettingsService.set(:librivox_url, "")

    error = assert_raises LibrivoxClient::NotConfiguredError do
      LibrivoxClient.search(title: "Pride")
    end
    assert_equal "LibriVox is not enabled", error.message
    assert_raises LibrivoxClient::NotConfiguredError do
      LibrivoxClient.send(:connection)
    end
    assert_requested :get, %r{old-librivox\.example/api/feed/audiobooks/}, times: 1
    assert_not_requested :get, %r{https://librivox\.org/}
    assert_nil LibrivoxClient.instance_variable_get(:@connection)
    assert_nil LibrivoxClient.instance_variable_get(:@connection_settings_key)
  end

  test "configured URL must be an origin" do
    SettingsService.set(:librivox_url, "https://librivox.org/api/feed")

    assert_raises LibrivoxClient::ConfigurationError do
      LibrivoxClient.search(title: "test")
    end
  end

  private

  def stub_title_search(title, status: 200, books: [], limit: 10)
    stub_request(:get, "https://librivox.org/api/feed/audiobooks/")
      .with(query: hash_including("title" => title, "limit" => limit.to_s))
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: { books: books }.to_json)
  end

  def audiobook(title)
    { id: "177", title: title, language: "English", url_zip_file: "https://archive.org/download/example/book.zip" }
  end
end
