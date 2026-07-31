# frozen_string_literal: true

# Imports an admin-approved DetectedImport into the organised library via
# LibraryAcquisitionService. Claims the record with a compare-and-swap so a
# double submit or redelivery cannot run two imports for the same detection.
# A failed import leaves the source untouched and is retryable from the review
# queue.
class DetectedImportJob < ApplicationJob
  queue_as :default

  # One import at a time per detection. The compare-and-swap below stops two
  # workers claiming the same row, but a row wedged past STUCK_IMPORTING_AFTER is
  # deliberately re-claimable — and without this lease a genuinely slow import
  # would still be running when the admin recovers it, letting the second worker
  # reverse what the first is finalizing. The lease serialises them instead.
  #
  # Its duration matches the stuck window on purpose: past that point the system
  # treats the claiming worker as dead, so the lease must expire with it or a
  # killed worker would block its own recovery for an hour.
  limits_concurrency(
    key: ->(detected_import_id) { "detected_import/#{detected_import_id}" },
    duration: DetectedImport::STUCK_IMPORTING_AFTER
  )

  def perform(detected_import_id)
    detected_import = claim(detected_import_id)
    return unless detected_import

    begin
      book = detected_import.suggested_book || create_and_attach_book(detected_import)

      result = LibraryAcquisitionService.import!(
        source_path: detected_import.source_path,
        book: book,
        owner: detected_import,
        provenance: :watched_folder,
        source_identity: detected_import.source_identity,
        source_base: WatchedFolderScanService.import_root
      )

      detected_import.update!(
        status: "imported",
        imported_book: result.book,
        suggested_book: result.book,
        error_message: nil
      )
      Rails.logger.info(
        "[DetectedImportJob] Imported detection ##{detected_import.id} into book ##{result.book.id}"
      )
    rescue => e
      Rails.logger.error(
        "[DetectedImportJob] Import failed for detection ##{detected_import.id} (#{e.class})"
      )
      detected_import.update!(
        status: "failed",
        error_message: e.message.to_s.scrub.truncate(2_000)
      )
    end
  end

  private

  # Compare-and-swap claimable -> importing, so only one worker proceeds while a
  # wedged row stays recoverable.
  def claim(detected_import_id)
    claimed = DetectedImport.claimable
      .where(id: detected_import_id)
      .update_all(status: "importing", updated_at: Time.current)
    return unless claimed == 1

    DetectedImport.find_by(id: detected_import_id)
  end

  # Persist the created Book onto the detection so a retry after a failed import
  # reuses it instead of orphaning a new unacquired record each attempt.
  def create_and_attach_book(detected_import)
    book = Book.create!(
      title: detected_import.parsed_title.presence || File.basename(detected_import.source_path.to_s),
      author: detected_import.parsed_author,
      book_type: detected_import.book_type.presence || "ebook"
    )
    detected_import.update!(suggested_book: book)
    book
  end
end
