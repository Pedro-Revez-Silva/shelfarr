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

    assert_not LibrivoxClient.test_connection
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

  test "configured URL must be an origin" do
    SettingsService.set(:librivox_url, "https://librivox.org/api/feed")

    assert_raises LibrivoxClient::ConfigurationError do
      LibrivoxClient.search(title: "test")
    end
  end
end
