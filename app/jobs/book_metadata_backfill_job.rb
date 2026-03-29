# frozen_string_literal: true

# Backfills missing book metadata from configured metadata providers.
# Safe by default: only fills blank fields and skips books without a work_id.
class BookMetadataBackfillJob < ApplicationJob
  queue_as :default

  def perform(book_ids: nil)
    books_for_backfill(book_ids).find_each do |book|
      work_id = book.unified_work_id
      next if work_id.blank?

      BookMetadataBackfillService.apply!(book, work_id: work_id)
    rescue StandardError => e
      Rails.logger.warn("[BookMetadataBackfillJob] Failed for book #{book.id}: #{e.message}")
    end
  end

  private

  def books_for_backfill(book_ids)
    return Book.where(id: book_ids) if book_ids.present?

    Book.where(series: [ nil, "" ])
  end
end
