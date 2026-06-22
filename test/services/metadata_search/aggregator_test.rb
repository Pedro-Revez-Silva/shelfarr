# frozen_string_literal: true

require "test_helper"

module MetadataSearch
  class AggregatorTest < ActiveSupport::TestCase
    test "merges results with shared isbn even when provider titles vary" do
      results = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL123W", title: "The Hobbit", isbn_13: "9780547928227"),
        provider_result(source: "google_books", source_id: "gb123", title: "The Hobbit: Or There and Back Again", isbn_13: "9780547928227")
      ], priority: %w[openlibrary google_books])

      assert_equal 1, results.size
      candidate = results.first
      assert_equal "isbn:9780547928227", candidate.canonical_key
      assert_equal "openlibrary:OL123W", candidate.work_id
      assert_equal %w[openlibrary google_books], candidate.sources.map { |source| source[:source] }
      assert_equal 100, candidate.confidence
    end

    test "merges results with normalized title author and close year when isbn is missing" do
      results = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL123W", title: "Dune!", author: "Frank Herbert", year: 1965),
        provider_result(source: "google_books", source_id: "gb123", title: "Dune", author: "Frank Herbert", year: 1966)
      ], priority: %w[openlibrary google_books])

      assert_equal 1, results.size
      assert_equal "openlibrary:OL123W", results.first.canonical_key
      assert_equal 90, results.first.confidence
    end

    test "keeps same title and author separate when isbn conflicts" do
      results = Aggregator.call([
        provider_result(source: "google_books", source_id: "paperback", title: "Dune", isbn_13: "9780441172719"),
        provider_result(source: "google_books", source_id: "hardcover", title: "Dune", isbn_13: "9780593099322")
      ], priority: %w[google_books])

      assert_equal 2, results.size
      assert_equal %w[google_books:paperback google_books:hardcover], results.map(&:work_id)
    end

    test "keeps same title and author separate when years are far apart" do
      results = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL1937W", title: "The Hobbit", author: "J.R.R. Tolkien", year: 1937),
        provider_result(source: "google_books", source_id: "gb2020", title: "The Hobbit", author: "J.R.R. Tolkien", year: 2020)
      ], priority: %w[openlibrary google_books])

      assert_equal 2, results.size
    end

    test "uses provider priority for primary source and first-present fields" do
      results = Aggregator.call([
        provider_result(source: "google_books", source_id: "gb123", description: "Google description", cover_url: "https://google.example/cover.jpg", has_ebook: true),
        provider_result(source: "openlibrary", source_id: "OL123W", description: nil, cover_url: nil, has_ebook: nil)
      ], priority: %w[openlibrary google_books])

      candidate = results.first
      assert_equal "openlibrary", candidate.source
      assert_equal "Google description", candidate.description
      assert_equal "https://google.example/cover.jpg", candidate.cover_url
      assert_equal true, candidate.has_ebook
      assert_equal 1, candidate.editions.size
    end

    test "merges transitive title author and year matches across provider chain" do
      results = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL_A", title: "Dune", author: "Frank Herbert", year: 1965),
        provider_result(source: "google_books", source_id: "GB_B", title: "Dune", author: "Frank Herbert", year: 1966),
        provider_result(source: "hardcover", source_id: "HC_C", title: "Dune", author: "Frank Herbert", year: 1965)
      ], priority: %w[openlibrary google_books hardcover])

      assert_equal 1, results.size
      assert_equal 3, results.first.sources.size
    end

    test "keeps same title separate when author metadata is missing" do
      results = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL_A", title: "Shared Title", author: nil, year: 2020),
        provider_result(source: "google_books", source_id: "GB_B", title: "Shared Title", author: nil, year: 2020)
      ], priority: %w[openlibrary google_books])

      assert_equal 2, results.size
    end

    test "returns false availability only when a provider explicitly reports false" do
      candidate = Aggregator.call([
        provider_result(source: "openlibrary", source_id: "OL123W", has_ebook: nil),
        provider_result(source: "google_books", source_id: "gb123", has_ebook: false)
      ], priority: %w[openlibrary google_books]).first

      assert_equal false, candidate.has_ebook
      assert_nil candidate.has_audiobook
    end

    private

    def provider_result(source:, source_id:, title: "The Hobbit", author: "J.R.R. Tolkien", year: 1937,
      description: nil, cover_url: nil, isbn_10: nil, isbn_13: nil, has_ebook: nil, has_audiobook: nil)
      ProviderResult.new(
        source: source,
        source_id: source_id,
        title: title,
        author: author,
        year: year,
        description: description,
        cover_url: cover_url,
        isbn_10: isbn_10,
        isbn_13: isbn_13,
        publisher: nil,
        page_count: nil,
        language: nil,
        series_name: nil,
        series_position: nil,
        has_ebook: has_ebook,
        has_audiobook: has_audiobook,
        source_url: "https://example.test/#{source_id}",
        raw_payload: nil
      )
    end
  end
end
