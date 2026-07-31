# frozen_string_literal: true

# A book file found in the watched-folder import path that was not acquired
# through a Shelfarr request. One record is one review-queue item: detected,
# matched, then approved or dismissed by an admin before import.
#
# Idempotency is anchored on the source (device, inode) rather than the path: a
# hardlink import creates a second path to the same content, and a re-scan must
# not re-detect it.
class DetectedImport < ApplicationRecord
  STATUSES = %w[detected dismissed importing imported failed].freeze
  ACTIONABLE_STATUSES = %w[detected failed].freeze
  BOOK_TYPES = %w[audiobook ebook comicbook].freeze

  # An "importing" row older than this is assumed abandoned — its worker died
  # before writing success or failure — so it becomes actionable and re-claimable.
  #
  # The claim is stamped once and never refreshed, so a genuinely slow import
  # also looks stuck. DetectedImportJob's concurrency lease uses the same
  # duration to cover that: the recovery attempt waits for the original to
  # finish instead of reversing it mid-flight.
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

  # Rows wedged in "importing" long enough that the claiming worker must be gone.
  # Both recovery sites — the job's compare-and-swap and the queue's manual retry
  # — go through this scope; #stuck_importing? is its in-memory mirror.
  scope :stuck_importing, -> { where(status: "importing").where(updated_at: ...STUCK_IMPORTING_AFTER.ago) }
  # Rows a worker may claim: never started, or abandoned by a dead worker.
  scope :claimable, -> { actionable.or(stuck_importing) }

  # Live-update the review screens on create, status change, and destroy (the
  # Turbo 8 morph-refresh pattern used on the request screens). The index tracks
  # the whole queue; each review page also tracks its own record so it swaps to
  # imported/failed without a reload.
  INDEX_STREAM = "detected_imports"
  after_create_commit  :broadcast_queue_refresh_later
  after_update_commit  :broadcast_review_refresh_later
  after_destroy_commit :broadcast_queue_refresh_later

  # Retire review-queue rows describing content another front door has already
  # imported, so the queue never offers a file that is now in the library.
  # Returns how many were dismissed.
  #
  # Matching runs both ways because the two sides name a release differently: the
  # importer reports the file it took, the scanner records an audiobook as its
  # containing folder. An enclosing folder is only ever one release — the scanner
  # splits multi-title folders into separate detections — so a detection above
  # the imported source describes the same book.
  def self.dismiss_for_imported_source!(source_path)
    return 0 if source_path.blank?

    # Detections are recorded under File.realpath of the import root, so a source
    # reaching the same content through a symlinked parent (/downloads ->
    # /data/downloads) spells it differently. Match both spellings.
    paths = [ source_path, canonical_source_path(source_path) ].uniq
    enclosing = paths.flat_map { |path| enclosing_detection_paths(path) }.uniq
    # SQLite's LIKE has no default escape character, so sanitize_sql_like's
    # backslashes are only inert with an explicit ESCAPE.
    nested_clauses = paths.each_index.map { |index| "source_path LIKE :nested#{index} ESCAPE '\\'" }
    binds = { paths: paths, enclosing: enclosing }
    paths.each_with_index do |path, index|
      binds[:"nested#{index}"] = "#{sanitize_sql_like(path)}/%"
    end

    dismissed = 0
    actionable
      .where(
        [ "source_path IN (:paths)", "source_path IN (:enclosing)", *nested_clauses ].join(" OR "),
        binds
      )
      .find_each do |detection|
        # One row at a time, so the screens get the same Turbo refresh a manual
        # dismissal broadcasts.
        detection.update!(status: "dismissed")
        dismissed += 1
      end
    dismissed
  end

  # Directories between an imported source and the watched-folder root — the only
  # paths above it a detection can occupy. Bounded by that root so the walk cannot
  # reach a shared parent outside the scanned tree; the root itself is excluded
  # because the scanner never records it as a release.
  #
  # Bounded by the scanner's canonical root, not the raw setting: detections live
  # beneath the canonical one, so a symlinked setting would bound the walk with a
  # prefix no detection carries.
  def self.enclosing_detection_paths(source_path)
    root = watched_folder_root
    return [] if root.blank?

    paths = []
    current = File.dirname(source_path)
    while current.start_with?("#{root}/")
      paths << current
      parent = File.dirname(current)
      break if parent == current

      current = parent
    end
    paths
  end
  private_class_method :enclosing_detection_paths

  # The root detections are actually recorded under. Falls back to the raw
  # setting when the scanner refuses that root (unset, missing, or overlapping an
  # output path) — there are no live detections to match then anyway.
  def self.watched_folder_root
    root = WatchedFolderScanService.import_root
    root.presence || SettingsService.get(:library_import_path).to_s.strip.chomp("/")
  end
  private_class_method :watched_folder_root

  # The path the scanner would have recorded. Only the parent is resolved: a move
  # import has already consumed the file itself, and realpath would raise on it.
  def self.canonical_source_path(source_path)
    File.join(File.realpath(File.dirname(source_path)), File.basename(source_path))
  rescue SystemCallError
    source_path
  end
  private_class_method :canonical_source_path

  def actionable?
    ACTIONABLE_STATUSES.include?(status) || stuck_importing?
  end

  # In-memory mirror of the .stuck_importing scope, kept in Ruby because the
  # review queue asks this of every row it renders.
  def stuck_importing?
    status == "importing" && updated_at.present? && updated_at < STUCK_IMPORTING_AFTER.ago
  end

  def imported?
    status == "imported"
  end

  # The (device, inode) recorded at detection, or nil on filesystems that report
  # no usable identity. The importer refuses a source whose inode no longer
  # matches, so a path swapped between detection and approval cannot substitute
  # different bytes.
  def source_identity
    return nil if source_device.blank? || source_inode.blank?

    [ source_device, source_inode ]
  end

  def display_title
    parsed_title.presence || File.basename(source_path.to_s)
  end

  def candidate_books
    value = super
    value.is_a?(Array) ? value : []
  end

  # The highest-scoring alternate — library book or online work — used to
  # pre-select a real match instead of "new book" when no exact suggestion
  # exists. Same ranking the review screen lists alternates in.
  def best_candidate
    candidate_books.max_by { |candidate| candidate["score"].to_i } if candidate_books.present?
  end

  # The radio the review form defaults to: the library suggestion, else the
  # best-scoring alternate, and only "new" when nothing matched.
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
