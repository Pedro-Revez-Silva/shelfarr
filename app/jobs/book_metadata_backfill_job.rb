# frozen_string_literal: true

# Backfills missing book metadata from configured metadata providers.
# Safe by default: only fills blank fields and skips books without a work_id.
class BookMetadataBackfillJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1,
    key: "book-metadata-backfill",
    duration: 2.hours

  SCHEDULED_BATCH_SIZE = 100
  RECHECK_INTERVAL = 30.days

  def perform(book_ids: nil)
    unavailable_sources = []
    unavailable_sources << "hardcover" unless HardcoverClient.configured?

    each_book_for_backfill(book_ids, unavailable_sources: unavailable_sources) do |book|
      result = backfill_book(book)
      unavailable_sources << "hardcover" if result == :hardcover_unavailable
    end
  end

  private

  def each_book_for_backfill(book_ids, unavailable_sources:)
    books = books_for_backfill(book_ids)
    if book_ids.present?
      ordered_for_backfill(books).each do |book|
        yield book unless source_unavailable?(book, unavailable_sources)
      end
      return
    end

    processed_ids = []
    processed_count = 0
    while processed_count < SCHEDULED_BATCH_SIZE
      candidates = exclude_unavailable_sources(books, unavailable_sources)
      candidates = candidates.where.not(id: processed_ids) if processed_ids.any?
      candidates = ordered_for_backfill(candidates)
        .limit(SCHEDULED_BATCH_SIZE - processed_count)
        .to_a
      break if candidates.empty?

      candidates.each do |book|
        processed_ids << book.id
        next if source_unavailable?(book, unavailable_sources)

        yield book
        processed_count += 1
      end
    end
  end

  def books_for_backfill(book_ids)
    return Book.where(id: book_ids) if book_ids.present?

    missing_series = Book.where(series: [ nil, "" ]).or(Book.where(series_position: [ nil, "" ]))
    missing_comic_run_year = Book.comicbooks
      .where(series_start_year: nil)
      .where("comic_vine_id LIKE ?", "4000-%")

    missing_metadata = missing_series.or(missing_comic_run_year)
    missing_metadata.where(
      "metadata_backfill_checked_at IS NULL OR metadata_backfill_checked_at <= ?",
      RECHECK_INTERVAL.ago
    )
  end

  def mark_checked!(book)
    book.update_column(:metadata_backfill_checked_at, Time.current)
  end

  def backfill_book(book)
    work_id = book.unified_work_id
    if work_id.blank?
      mark_checked!(book)
      return :processed
    end

    BookMetadataBackfillService.apply!(
      book,
      work_id: work_id,
      raise_lookup_errors: true
    )
    mark_checked!(book)
    :processed
  rescue HardcoverClient::NotFoundError
    mark_checked!(book)
    :processed
  rescue HardcoverClient::RateLimitError,
         HardcoverClient::AuthenticationError,
         HardcoverClient::ConnectionError => e
    MetadataProviderStatus.for_provider("hardcover").record_failure!(e)
    Rails.logger.warn("[BookMetadataBackfillJob] Skipping Hardcover after provider error: #{e.message}")
    :hardcover_unavailable
  rescue StandardError => e
    Rails.logger.warn("[BookMetadataBackfillJob] Failed for book #{book.id}: #{e.message}")
    :processed
  end

  def ordered_for_backfill(books)
    books.order(
      Arel.sql("metadata_backfill_checked_at IS NOT NULL ASC"),
      metadata_backfill_checked_at: :asc,
      id: :asc
    )
  end

  def exclude_unavailable_sources(books, unavailable_sources)
    if unavailable_sources.include?("hardcover")
      books = books.where(hardcover_id: [ nil, "" ])
    end
    books
  end

  def source_unavailable?(book, unavailable_sources)
    source, = Book.parse_work_id(book.unified_work_id)
    unavailable_sources.include?(source)
  end
end
