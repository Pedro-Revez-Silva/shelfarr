# frozen_string_literal: true

require "test_helper"

class OpenLibraryClientTest < ActiveSupport::TestCase
  test "search skips requests shorter than 3 characters" do
    VCR.turned_off do
      request = stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
        .with(query: hash_including(
          "fields" => "key,title,author_name,first_publish_year,cover_i,edition_count,subject"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "docs" => [] }.to_json
        )

      assert_equal [], OpenLibraryClient.search("Du")
      assert_equal [], OpenLibraryClient.search("  x ")
      assert_not_requested request

      assert_equal [], OpenLibraryClient.search("Dun")
      assert_requested request
    end
  end

  test "search raises QueryError when the query is rejected" do
    VCR.turned_off do
      [ 400, 422 ].each do |status|
        stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
          .with(query: hash_including("q" => "Dune"))
          .to_return(
            status: status,
            headers: { "Content-Type" => "application/json" },
            body: "{}"
          )

        error = assert_raises(OpenLibraryClient::QueryError) { OpenLibraryClient.search("Dune") }
        assert_equal "API request failed with status #{status}", error.message
      end
    end
  end

  test "search raises Error when Open Library returns a server error" do
    VCR.turned_off do
      stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
        .with(query: hash_including("q" => "Dune"))
        .to_return(
          status: 500,
          headers: { "Content-Type" => "application/json" },
          body: "{}"
        )

      error = assert_raises(OpenLibraryClient::Error) { OpenLibraryClient.search("Dune") }

      assert_equal OpenLibraryClient::Error, error.class
      assert_equal "API request failed with status 500", error.message
    end
  end

  test "search returns array of SearchResult" do
    with_cassette("open_library/search_harry_potter") do
      results = OpenLibraryClient.search("harry potter")

      assert_kind_of Array, results
      assert results.any?
      assert_kind_of OpenLibraryClient::SearchResult, results.first

      result = results.first
      assert result.title.present?
      assert result.work_id.present?
    end
  end

  test "search returns empty array for no results" do
    with_cassette("open_library/search_no_results") do
      results = OpenLibraryClient.search("asdfghjklqwertyuiop123456789")
      assert_equal [], results
    end
  end

  test "search respects limit parameter" do
    with_cassette("open_library/search_with_limit") do
      results = OpenLibraryClient.search("fiction", limit: 5)
      assert results.length <= 5
    end
  end

  test "search requests and retains subjects" do
    VCR.turned_off do
      stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
        .with(query: hash_including(
          "q" => "saga",
          "fields" => "key,title,author_name,first_publish_year,cover_i,edition_count,subject"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "docs" => [
              {
                "key" => "/works/OL123W",
                "title" => "Saga",
                "subject" => [ "Comic books, strips, etc.", "Space opera" ]
              }
            ]
          }.to_json
        )

      result = OpenLibraryClient.search("saga", limit: 1).first

      assert_equal [ "Comic books, strips, etc.", "Space opera" ], result.subjects
    end
  end

  test "work returns WorkDetails" do
    with_cassette("open_library/work_details") do
      work = OpenLibraryClient.work("OL45804W")

      assert_kind_of OpenLibraryClient::WorkDetails, work
      assert_equal "OL45804W", work.work_id
      assert work.title.present?
    end
  end

  test "work raises NotFoundError for invalid id" do
    with_cassette("open_library/work_not_found") do
      assert_raises OpenLibraryClient::NotFoundError do
        OpenLibraryClient.work("OL999999999W")
      end
    end
  end

  test "edition returns EditionDetails" do
    with_cassette("open_library/edition_details") do
      edition = OpenLibraryClient.edition("OL22856696M")

      assert_kind_of OpenLibraryClient::EditionDetails, edition
      assert edition.title.present?
    end
  end

  test "cover_url generates correct URL" do
    url = OpenLibraryClient.cover_url(12345, size: :m)
    assert_equal "https://covers.openlibrary.org/b/id/12345-M.jpg", url

    url_large = OpenLibraryClient.cover_url(12345, size: :l)
    assert_equal "https://covers.openlibrary.org/b/id/12345-L.jpg", url_large
  end

  test "cover_url returns nil for blank cover_id" do
    assert_nil OpenLibraryClient.cover_url(nil)
    assert_nil OpenLibraryClient.cover_url("")
  end

  test "SearchResult generates cover_url from cover_id" do
    result = OpenLibraryClient::SearchResult.new(
      work_id: "OL123W",
      title: "Test Book",
      author: "Test Author",
      first_publish_year: 2020,
      cover_id: 12345,
      edition_count: 5
    )

    assert_equal "https://covers.openlibrary.org/b/id/12345-M.jpg", result.cover_url
    assert_equal "https://covers.openlibrary.org/b/id/12345-L.jpg", result.cover_url(size: :l)
  end
end
