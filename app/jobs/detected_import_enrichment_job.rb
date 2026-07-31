# frozen_string_literal: true

# Fills in a detection's online alternates out-of-band, so the watched-folder
# scan stays local + DB only and never blocks on thousands of sequential provider
# searches. Non-destructive: it appends candidates the scan didn't record and
# leaves the parsed metadata and library suggestion alone. Failures are swallowed
# — admin review and the manual Re-match are the correctness backstop.
class DetectedImportEnrichmentJob < ApplicationJob
  queue_as :default

  def perform(detected_import_id)
    detected_import = DetectedImport.find_by(id: detected_import_id)
    return unless detected_import
    return unless detected_import.status == "detected"

    online = LibraryAcquisitionService.online_candidates_for(
      title: detected_import.parsed_title,
      author: detected_import.parsed_author,
      book_type: detected_import.book_type
    )
    return if online.empty?

    existing = detected_import.candidate_books
    known_work_ids = existing.map { |candidate| candidate["work_id"] }.compact.to_set
    additions = online.reject { |candidate| known_work_ids.include?(candidate["work_id"]) }
    return if additions.empty?

    detected_import.update!(candidate_books: existing + additions)
  rescue => e
    Rails.logger.warn "[DetectedImportEnrichmentJob] Enrichment failed for ##{detected_import_id} (#{e.class})"
  end
end
