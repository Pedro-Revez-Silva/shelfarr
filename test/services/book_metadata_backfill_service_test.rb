# frozen_string_literal: true

require "test_helper"

class BookMetadataBackfillServiceTest < ActiveSupport::TestCase
  test "fills blank fields from metadata details and fallback attrs for a new book" do
    book = Book.new(book_type: :ebook)
    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "123",
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      description: "Book one of The Expanse",
      year: 2011,
      cover_url: "https://example.com/cover.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "The Expanse"
    )

    result = MetadataService.stub(:book_details, details) do
      BookMetadataBackfillService.apply!(
        book,
        work_id: "hardcover:123",
        fallback_attrs: {
          title: "Fallback Title",
          author: "Fallback Author",
          year: 2000
        }
      )
    end

    assert result
    assert_predicate book, :persisted?
    assert_equal "Leviathan Wakes", book.title
    assert_equal "James S. A. Corey", book.author
    assert_equal "Book one of The Expanse", book.description
    assert_equal "The Expanse", book.series
    assert_equal 2011, book.year
    assert_equal "https://example.com/cover.jpg", book.cover_url
    assert_equal "hardcover", book.metadata_source
  end

  test "does not overwrite existing nonblank fields" do
    book = Book.create!(
      title: "Existing Title",
      author: "Existing Author",
      book_type: :ebook,
      hardcover_id: "456",
      description: "Existing description",
      cover_url: "https://example.com/existing.jpg",
      year: 1999,
      series: "Existing Series",
      metadata_source: "openlibrary"
    )

    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "456",
      title: "Fetched Title",
      author: "Fetched Author",
      description: "Fetched description",
      year: 2011,
      cover_url: "https://example.com/fetched.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "Fetched Series"
    )

    result = MetadataService.stub(:book_details, details) do
      BookMetadataBackfillService.apply!(book, work_id: "hardcover:456")
    end

    assert_not result
    book.reload
    assert_equal "Existing Title", book.title
    assert_equal "Existing Author", book.author
    assert_equal "Existing description", book.description
    assert_equal "Existing Series", book.series
    assert_equal 1999, book.year
    assert_equal "https://example.com/existing.jpg", book.cover_url
    assert_equal "openlibrary", book.metadata_source
  end

  test "falls back to provided attrs when metadata lookup fails" do
    book = Book.new(book_type: :ebook)

    result = MetadataService.stub(:book_details, ->(*) { raise OpenLibraryClient::ConnectionError, "timeout" }) do
      BookMetadataBackfillService.apply!(
        book,
        work_id: "openlibrary:OL123W",
        fallback_attrs: {
          title: "Fallback Title",
          author: "Fallback Author",
          year: 2001
        }
      )
    end

    assert result
    assert_equal "Fallback Title", book.title
    assert_equal "Fallback Author", book.author
    assert_equal 2001, book.year
    assert_equal "openlibrary", book.metadata_source
    assert_nil book.series
  end

  test "returns false when there is nothing to fill" do
    book = Book.create!(
      title: "Complete Book",
      author: "Known Author",
      book_type: :ebook,
      hardcover_id: "999",
      description: "Known description",
      cover_url: "https://example.com/cover.jpg",
      year: 2020,
      series: "Known Series",
      metadata_source: "hardcover"
    )

    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "999",
      title: "Fetched Title",
      author: "Fetched Author",
      description: "Fetched description",
      year: 2021,
      cover_url: "https://example.com/new-cover.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "Fetched Series"
    )

    assert_no_changes -> { book.reload.updated_at } do
      result = MetadataService.stub(:book_details, details) do
        BookMetadataBackfillService.apply!(book, work_id: "hardcover:999")
      end

      assert_not result
    end
  end
end
