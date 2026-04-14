# frozen_string_literal: true

require "test_helper"

class BookMetadataBackfillJobTest < ActiveJob::TestCase
  test "processes books with blank series or series position by default" do
    blank_series = Book.create!(
      title: "Blank Series",
      author: "Author One",
      book_type: :ebook,
      hardcover_id: "100",
      series: nil
    )
    blank_series_position = Book.create!(
      title: "Blank Series Position",
      author: "Author One",
      book_type: :ebook,
      hardcover_id: "102",
      series: "Known Series",
      series_position: nil
    )
    filled_series = Book.create!(
      title: "Filled Series",
      author: "Author Two",
      book_type: :ebook,
      hardcover_id: "101",
      series: "Known Series",
      series_position: "3"
    )

    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, work_id:, fallback_attrs: {}|
      processed << [ book.id, work_id, fallback_attrs ]
      true
    }) do
      BookMetadataBackfillJob.perform_now
    end

    processed_ids = processed.map(&:first)

    assert_includes processed_ids, blank_series.id
    assert_includes processed_ids, blank_series_position.id
    assert_not_includes processed_ids, filled_series.id
    assert_equal "Known Series", filled_series.reload.series
  end

  test "backfills missing series without overwriting existing data" do
    book = Book.create!(
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      book_type: :ebook,
      hardcover_id: "789",
      description: "Existing description",
      series: nil
    )

    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "789",
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      description: "Fetched description",
      year: 2011,
      cover_url: "https://example.com/cover.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "The Expanse",
      series_position: "1"
    )

    MetadataService.stub(:book_details, details) do
      BookMetadataBackfillJob.perform_now(book_ids: [ book.id ])
    end

    book.reload
    assert_equal "The Expanse", book.series
    assert_equal "1", book.series_position
    assert_equal "Existing description", book.description
    assert_equal 2011, book.year
    assert_equal "https://example.com/cover.jpg", book.cover_url
  end

  test "skips books without a work id" do
    book = Book.create!(
      title: "Standalone Book",
      author: "No Source",
      book_type: :ebook,
      series: nil,
      series_position: nil
    )

    MetadataService.stub(:book_details, ->(*) { flunk "book_details should not be called without a work_id" }) do
      assert_nothing_raised do
        BookMetadataBackfillJob.perform_now(book_ids: [ book.id ])
      end
    end

    assert_nil book.reload.series
  end

  test "continues processing when one book backfill raises" do
    first_book = Book.create!(
      title: "First Book",
      author: "Author One",
      book_type: :ebook,
      hardcover_id: "201",
      series: nil,
      series_position: nil
    )
    second_book = Book.create!(
      title: "Second Book",
      author: "Author Two",
      book_type: :ebook,
      hardcover_id: "202",
      series: nil,
      series_position: nil
    )

    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, work_id:, fallback_attrs: {}|
      processed << work_id
      raise "boom" if book.id == first_book.id

      book.update!(series: "Recovered Series", series_position: "4")
    }) do
      assert_nothing_raised do
        BookMetadataBackfillJob.perform_now(book_ids: [ first_book.id, second_book.id ])
      end
    end

    assert_equal %w[hardcover:201 hardcover:202], processed.sort
    assert_nil first_book.reload.series
    assert_equal "Recovered Series", second_book.reload.series
    assert_equal "4", second_book.reload.series_position
  end
end
