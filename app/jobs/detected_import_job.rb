# frozen_string_literal: true

# Imports an admin-approved DetectedImport into the organised library via
# LibraryAcquisitionService. Claims the record with a compare-and-swap so a
# double submit or redelivery cannot run two imports for the same detection.
# A failed import leaves the source untouched and is retryable from the review
# queue.
class DetectedImportJob < ApplicationJob
  queue_as :default

  def perform(detected_import_id)
    detected_import = claim(detected_import_id)
    return unless detected_import

    begin
      book = detected_import.suggested_book || create_and_attach_book(detected_import)

      result = LibraryAcquisitionService.import!(
        source_path: detected_import.source_path,
        book: book,
        owner: detected_import,
        provenance: :watched_folder
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

  # Compare-and-swap detected/failed (or an abandoned, stale "importing" whose
  # worker died before finishing) -> importing, so only one worker proceeds and
  # a wedged row can be recovered.
  def claim(detected_import_id)
    claimed = DetectedImport
      .where(id: detected_import_id)
      .where(
        "status IN (:actionable) OR (status = 'importing' AND updated_at < :stuck_before)",
        actionable: DetectedImport::ACTIONABLE_STATUSES,
        stuck_before: DetectedImport::STUCK_IMPORTING_AFTER.ago
      )
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
