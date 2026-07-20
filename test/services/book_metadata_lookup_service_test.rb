# frozen_string_literal: true

require "test_helper"

class BookMetadataLookupServiceTest < ActiveSupport::TestCase
  test "fills missing primary metadata from alternate source identifiers" do
    primary = metadata_details(
      source: "openlibrary",
      source_id: "OL123W",
      title: "Primary title",
      description: nil
    )
    alternate = metadata_details(
      source: "google_books",
      source_id: "gb-123",
      title: "Alternate title",
      description: "Description from the alternate provider"
    )

    lookup = lambda do |work_id|
      work_id == "openlibrary:OL123W" ? primary : alternate
    end

    metadata = MetadataService.stub(:book_details, lookup) do
      BookMetadataLookupService.call([ "openlibrary:OL123W", "google_books:gb-123" ])
    end

    assert_equal "Primary title", metadata[:title]
    assert_equal "Description from the alternate provider", metadata[:description]
  end

  test "continues with alternate identifiers when the primary lookup fails" do
    alternate = metadata_details(
      source: "google_books",
      source_id: "gb-123",
      title: "Recovered title",
      description: "Recovered description"
    )
    lookup = lambda do |work_id|
      raise OpenLibraryClient::ConnectionError, "timeout" if work_id == "openlibrary:OL123W"

      alternate
    end

    metadata = MetadataService.stub(:book_details, lookup) do
      BookMetadataLookupService.call([ "openlibrary:OL123W", "google_books:gb-123" ])
    end

    assert_equal "Recovered title", metadata[:title]
    assert_equal "Recovered description", metadata[:description]
  end

  test "skips alternate lookups when primary and fallback metadata are complete" do
    calls = []
    primary = metadata_details(
      source: "openlibrary",
      source_id: "OL123W",
      title: "Primary title",
      description: nil
    )
    lookup = lambda do |work_id|
      calls << work_id
      primary
    end

    MetadataService.stub(:book_details, lookup) do
      BookMetadataLookupService.call(
        [ "openlibrary:OL123W", "google_books:gb-123" ],
        fallback: { description: "Cached description" }
      )
    end

    assert_equal [ "openlibrary:OL123W" ], calls
  end

  test "normalizes to one bounded identifier per supported provider" do
    oversized = "openlibrary:#{'x' * BookMetadataLookupService::MAX_WORK_ID_BYTES}"
    work_ids = [
      "OL123W",
      "openlibrary:OL456W",
      "google_books:gb-1",
      "google_books:gb-2",
      "hardcover:123",
      "comic_vine:4000-123",
      "unsupported:123",
      oversized
    ]

    assert_equal(
      [
        "openlibrary:OL123W",
        "google_books:gb-1",
        "hardcover:123",
        "comic_vine:4000-123"
      ],
      BookMetadataLookupService.normalize_work_ids(work_ids)
    )
  end

  private

  def metadata_details(source:, source_id:, title:, description:)
    MetadataService::SearchResult.new(
      source: source,
      source_id: source_id,
      title: title,
      author: "Example Author",
      description: description,
      year: 2026,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: true,
      series_name: nil,
      series_position: nil
    )
  end
end
