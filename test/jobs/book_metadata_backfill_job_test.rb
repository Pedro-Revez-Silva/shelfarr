# frozen_string_literal: true

require "test_helper"

class BookMetadataBackfillJobTest < ActiveJob::TestCase
  setup do
    Book.update_all(metadata_backfill_checked_at: Time.current)
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "backfill-test-token")
  end

  test "processes books with blank series metadata or missing Comic Vine run years by default" do
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
    missing_comic_run_year = Book.create!(
      title: "Batman - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-105811",
      series: "Batman",
      series_position: "1",
      series_start_year: nil
    )

    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, work_id:, fallback_attrs: {}, raise_lookup_errors:|
      processed << [ book.id, work_id, fallback_attrs ]
      assert raise_lookup_errors
      true
    }) do
      BookMetadataBackfillJob.perform_now
    end

    processed_ids = processed.map(&:first)

    assert_includes processed_ids, blank_series.id
    assert_includes processed_ids, blank_series_position.id
    assert_includes processed_ids, missing_comic_run_year.id
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

    BookMetadataBackfillService.stub(:apply!, lambda { |book, work_id:, fallback_attrs: {}, raise_lookup_errors:|
      processed << work_id
      assert raise_lookup_errors
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

  test "records a successful negative lookup so standalone books are not retried daily" do
    book = Book.create!(
      title: "Standalone Hardcover Book",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "301",
      series: nil,
      series_position: nil
    )
    calls = 0

    BookMetadataBackfillService.stub(:apply!, lambda { |_book, work_id:, raise_lookup_errors:, **|
      calls += 1
      assert_equal "hardcover:301", work_id
      assert raise_lookup_errors
      false
    }) do
      BookMetadataBackfillJob.perform_now
      BookMetadataBackfillJob.perform_now
    end

    assert_equal 1, calls
    assert_in_delta Time.current, book.reload.metadata_backfill_checked_at, 1.second
  end

  test "scheduled runs process at most one bounded batch" do
    books = 101.times.map do |index|
      Book.create!(
        title: "Batch Book #{index}",
        author: "Author",
        book_type: :ebook,
        hardcover_id: (10_000 + index).to_s,
        series: nil,
        series_position: nil
      )
    end
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, **|
      processed << book.id
      false
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert_equal BookMetadataBackfillJob::SCHEDULED_BATCH_SIZE, processed.size
    assert_equal books.first(100).map(&:id), processed
    assert books.first.reload.metadata_backfill_checked_at.present?
    assert_nil books.last.reload.metadata_backfill_checked_at
  end

  test "stops probing Hardcover after the first rate limit" do
    first_book = Book.create!(
      title: "First Limited Book",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "401",
      series: nil,
      series_position: nil
    )
    second_book = Book.create!(
      title: "Second Limited Book",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "402",
      series: nil,
      series_position: nil
    )
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, **|
      processed << book.id
      raise HardcoverClient::RateLimitError.new("limited", retry_after: 120)
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert_equal [ first_book.id ], processed
    assert_nil first_book.reload.metadata_backfill_checked_at
    assert_nil second_book.reload.metadata_backfill_checked_at
  end

  test "continues other providers after Hardcover becomes unavailable" do
    hardcover_books = 100.times.map do |index|
      Book.create!(
        title: "Limited Hardcover Book #{index}",
        author: "Author",
        book_type: :ebook,
        hardcover_id: (20_000 + index).to_s,
        series: nil,
        series_position: nil
      )
    end
    openlibrary_book = Book.create!(
      title: "Open Library Book",
      author: "Author",
      book_type: :ebook,
      open_library_work_id: "OL-MIXED-W",
      series: nil,
      series_position: nil
    )
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |_book, work_id:, **|
      processed << work_id
      if work_id.start_with?("hardcover:")
        raise HardcoverClient::RateLimitError.new("limited", retry_after: 120)
      end

      false
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert_equal [ "hardcover:#{hardcover_books.first.hardcover_id}", "openlibrary:OL-MIXED-W" ], processed
    assert_nil hardcover_books.first.reload.metadata_backfill_checked_at
    assert openlibrary_book.reload.metadata_backfill_checked_at.present?
  end

  test "prioritizes never checked books ahead of stale low ids" do
    stale_books = 100.times.map do |index|
      Book.create!(
        title: "Stale Book #{index}",
        author: "Author",
        book_type: :ebook,
        hardcover_id: (30_000 + index).to_s,
        series: nil,
        series_position: nil,
        metadata_backfill_checked_at: 31.days.ago
      )
    end
    never_checked = Book.create!(
      title: "Never Checked",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "30999",
      series: nil,
      series_position: nil
    )
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |book, **|
      processed << book.id
      false
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert_equal BookMetadataBackfillJob::SCHEDULED_BATCH_SIZE, processed.size
    assert_equal never_checked.id, processed.first
    assert_includes processed, never_checked.id
    assert_not_includes processed, stale_books.last.id
  end

  test "disabling Hardcover prevents automated Hardcover calls without blocking other providers" do
    SettingsService.set(:hardcover_enabled, false)
    hardcover_book = Book.create!(
      title: "Disabled Hardcover Book",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "32001",
      series: nil,
      series_position: nil
    )
    openlibrary_book = Book.create!(
      title: "Enabled Open Library Book",
      author: "Author",
      book_type: :ebook,
      open_library_work_id: "OL-ENABLED-W",
      series: nil,
      series_position: nil
    )
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |_book, work_id:, **|
      processed << work_id
      false
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert_equal [ "openlibrary:OL-ENABLED-W" ], processed
    assert_nil hardcover_book.reload.metadata_backfill_checked_at
    assert openlibrary_book.reload.metadata_backfill_checked_at.present?
  end

  test "leaves transient failures eligible for the next scheduled run" do
    book = Book.create!(
      title: "Transient Failure",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "501",
      series: nil,
      series_position: nil
    )
    calls = 0

    BookMetadataBackfillService.stub(:apply!, lambda { |_book, **|
      calls += 1
      raise OpenLibraryClient::ConnectionError, "timeout" if calls == 1

      false
    }) do
      BookMetadataBackfillJob.perform_now
      assert_nil book.reload.metadata_backfill_checked_at
      BookMetadataBackfillJob.perform_now
    end

    assert_equal 2, calls
    assert book.reload.metadata_backfill_checked_at.present?
  end

  test "explicit book ids bypass the scheduled staleness filter" do
    book = Book.create!(
      title: "Explicit Refresh",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "601",
      series: nil,
      series_position: nil,
      metadata_backfill_checked_at: Time.current
    )
    processed = []

    BookMetadataBackfillService.stub(:apply!, lambda { |candidate, **|
      processed << candidate.id
      false
    }) do
      BookMetadataBackfillJob.perform_now(book_ids: [ book.id ])
    end

    assert_equal [ book.id ], processed
  end

  test "books without a provider id are marked checked so they cannot starve the batch" do
    book = Book.create!(
      title: "No Provider ID",
      author: "Author",
      book_type: :ebook,
      series: nil,
      series_position: nil
    )

    BookMetadataBackfillService.stub(:apply!, ->(*) { flunk "backfill should not be called" }) do
      BookMetadataBackfillJob.perform_now
    end

    assert book.reload.metadata_backfill_checked_at.present?
  end

  test "not found responses are recorded as a completed check" do
    book = Book.create!(
      title: "Removed Upstream Book",
      author: "Author",
      book_type: :ebook,
      hardcover_id: "701",
      series: nil,
      series_position: nil
    )

    BookMetadataBackfillService.stub(:apply!, lambda { |*|
      raise HardcoverClient::NotFoundError, "not found"
    }) do
      BookMetadataBackfillJob.perform_now
    end

    assert book.reload.metadata_backfill_checked_at.present?
  end
end
