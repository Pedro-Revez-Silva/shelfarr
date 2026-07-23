# frozen_string_literal: true

# A book file discovered in the watched-folder import path that was not acquired
# through a Shelfarr request. Each record represents one review-queue item: the
# scanner detects a candidate, computes a suggested match, and an admin approves
# or dismisses it before it is imported into the organised library.
#
# Idempotency is anchored on the source (device, inode) pair rather than the
# path, because a hardlink import creates a second path to the same content on
# the same filesystem and a re-scan must not re-detect it.
class DetectedImport < ApplicationRecord
  STATUSES = %w[detected dismissed importing imported failed].freeze
  ACTIONABLE_STATUSES = %w[detected failed].freeze
  BOOK_TYPES = %w[audiobook ebook comicbook].freeze

  # An "importing" row whose claim is older than this is assumed abandoned: the
  # worker that claimed it died (redeploy, OOM, hard kill) before it could reach
  # the success/failure update. Matches DetectedImportJob's concurrency lease so
  # a genuinely long import is never treated as stuck. Such rows become
  # actionable again (re-import / dismiss) and re-claimable by the job.
  STUCK_IMPORTING_AFTER = 1.hour

  belongs_to :suggested_book, class_name: "Book", optional: true
  belongs_to :imported_book, class_name: "Book", optional: true

  validates :source_path, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :book_type, inclusion: { in: BOOK_TYPES }, allow_nil: true

  scope :detected, -> { where(status: "detected") }
  scope :actionable, -> { where(status: ACTIONABLE_STATUSES) }
  scope :pending_review, -> { where(status: %w[detected failed importing]) }
  scope :recent, -> { order(Arel.sql("COALESCE(detected_at, created_at) DESC")) }

  # Live-update the review screens whenever a detection is created (scanner),
  # changes status (detected -> importing -> imported/failed via
  # DetectedImportJob), or is removed. Mirrors the Turbo 8 morph-refresh pattern
  # used on the request and owned-library screens. The index tracks the whole
  # queue via a shared stream; each review (show) page tracks just its own
  # record so it swaps to the imported/failed state without a manual reload.
  INDEX_STREAM = "detected_imports"
  after_create_commit  :broadcast_queue_refresh_later
  after_update_commit  :broadcast_review_refresh_later
  after_destroy_commit :broadcast_queue_refresh_later

  def actionable?
    ACTIONABLE_STATUSES.include?(status) || stuck_importing?
  end

  # True when this row has been wedged in "importing" long enough that the
  # claiming worker must be gone, so the admin can recover it from the queue.
  def stuck_importing?
    status == "importing" && updated_at.present? && updated_at < STUCK_IMPORTING_AFTER.ago
  end

  def imported?
    status == "imported"
  end

  def display_title
    parsed_title.presence || File.basename(source_path.to_s)
  end

  def candidate_books
    value = super
    value.is_a?(Array) ? value : []
  end

  # The highest-scoring alternate the scanner found, whether an existing library
  # book or an online work. Used to pre-select a real match instead of "new
  # book" when no exact library suggestion exists — the same ranking the review
  # screen lists the alternates in.
  def best_candidate
    candidate_books.max_by { |candidate| candidate["score"].to_i } if candidate_books.present?
  end

  # The radio value the review form should default to: the existing library
  # suggestion when there is one, otherwise the best-scoring alternate, and only
  # "new" when nothing was matched at all.
  def default_selection
    return "book:#{suggested_book_id}" if suggested_book_id

    candidate = best_candidate
    return "new" unless candidate

    candidate["kind"] == "library" ? "book:#{candidate['book_id']}" : "work:#{candidate['work_id']}"
  end

  private

  def broadcast_queue_refresh_later
    broadcast_refresh_later_to(INDEX_STREAM)
  end

  def broadcast_review_refresh_later
    broadcast_refresh_later_to(INDEX_STREAM)
    broadcast_refresh_later_to(self)
  end
end
