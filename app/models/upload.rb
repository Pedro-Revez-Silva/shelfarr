# frozen_string_literal: true

class Upload < ApplicationRecord
  belongs_to :user
  belongs_to :book, optional: true
  belongs_to :request, optional: true

  enum :status, {
    pending: 0,
    processing: 1,
    completed: 2,
    failed: 3
  }

  enum :book_type, { audiobook: 0, ebook: 1, comicbook: 2 }

  # Supported file extensions
  AUDIOBOOK_EXTENSIONS = %w[m4a m4b mp3 zip rar].freeze
  EBOOK_EXTENSIONS = %w[epub pdf mobi azw3].freeze
  COMICBOOK_EXTENSIONS = %w[cbz cbr].freeze
  SUPPORTED_EXTENSIONS = (AUDIOBOOK_EXTENSIONS + EBOOK_EXTENSIONS + COMICBOOK_EXTENSIONS).freeze

  validates :original_filename, presence: true
  validates :status, presence: true

  before_destroy :prevent_unsafe_destruction
  before_destroy :prune_manual_match_before_destroy
  before_destroy :remove_unprocessed_file

  scope :recent, -> { order(created_at: :desc) }
  scope :pending_or_processing, -> { where(status: [ :pending, :processing ]) }
  scope :blocking_reservations, -> {
    where.not(status: :completed)
      .where("destination_path IS NOT NULL OR library_path IS NOT NULL")
  }
  scope :cancellation_blocking, -> {
    active = where(status: [ :pending, :processing ])
    recovery_state = where.not(status: :completed).where(
      "COALESCE(destination_path, '') != '' OR " \
        "COALESCE(destination_root, '') != '' OR " \
        "COALESCE(destination_configured_root, '') != '' OR " \
        "COALESCE(library_path, '') != '' OR " \
        "COALESCE(content_sha256, '') != '' OR " \
        "COALESCE(cleanup_source_path, '') != '' OR " \
        "COALESCE(book_reservation_token, '') != ''"
    )
    active.or(recovery_state)
  }

  def file_extension
    File.extname(original_filename).delete(".").downcase
  end

  def audiobook_file?
    AUDIOBOOK_EXTENSIONS.include?(file_extension)
  end

  def ebook_file?
    EBOOK_EXTENSIONS.include?(file_extension)
  end

  def comicbook_file?
    COMICBOOK_EXTENSIONS.include?(file_extension)
  end

  def archive_file?
    %w[zip rar].include?(file_extension)
  end

  def infer_book_type
    return :comicbook if comicbook_file?

    audiobook_file? ? :audiobook : :ebook
  end

  def display_status
    case status
    when "pending" then "Waiting to process"
    when "processing" then "Processing..."
    when "completed" then "Completed"
    when "failed" then "Failed: #{error_message}"
    end
  end

  def recovery_state?
    %i[
      destination_path
      destination_root
      destination_configured_root
      library_path
      content_sha256
      cleanup_source_path
      book_reservation_token
    ].any? { |attribute| public_send(attribute).present? }
  end

  def manual_match_available?
    failed? && request_id.nil? && !recovery_state? &&
      !OwnedMediaImport.exists?(upload_id: id)
  end

  # Choose only before publication has reserved a destination. Retries with
  # recovery state must reconcile that destination using the original Book.
  def match_and_retry!(book_id: nil, title: nil, author: nil)
    with_lock do
      errors.clear
      unless manual_match_available?
        errors.add(:base, "Only failed standalone uploads without reserved files can be matched. Use Retry to reconcile a reserved file.")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      previous_owned_book_id = self.book_id if manual_match? && manual_match_created_book?
      selected_book = if book_id.present?
        Book.lock.find(book_id)
      else
        Book.new(title: title.to_s.strip, author: author.to_s.strip.presence,
          book_type: infer_book_type, content_kind: comicbook_file? ? :graphic : :book)
      end

      if selected_book.book_type != infer_book_type.to_s
        errors.add(:base, "Choose a book with the same format as this upload.")
      elsif selected_book.acquisition_blocked?
        errors.add(:base, "This book already has a library file or an acquisition in progress. Choose another book.")
      end
      raise ActiveRecord::RecordInvalid.new(self) if errors.any?

      owns_selected_book = selected_book.new_record? || previous_owned_book_id == selected_book.id
      selected_book.save! if selected_book.new_record?
      update!(book: selected_book, book_type: infer_book_type, manual_match: true,
        manual_match_created_book: owns_selected_book, status: :pending, error_message: nil)
      prune_abandoned_manual_book(previous_owned_book_id) if previous_owned_book_id != selected_book.id
    end
  end

  def destruction_blocked?
    return false if completed?
    return true if processing? || recovery_state?
    return false unless persisted?

    OwnedMediaImport.cancellation_blocking.where(upload_id: id).exists?
  end

  private

  def prevent_unsafe_destruction
    return unless destruction_blocked?

    errors.add(
      :base,
      "This upload is processing or owns recovery state and cannot be deleted safely"
    )
    throw :abort
  end

  def prune_manual_match_before_destroy
    return unless (failed? || pending?) && manual_match? && manual_match_created_book?

    # Prune metadata before unlinking ingress. A database error must not roll
    # back the upload deletion after its source bytes have already been removed.
    prune_abandoned_manual_book(book_id, excluding_upload_id: id)
  end

  def prune_abandoned_manual_book(book_id, excluding_upload_id: nil)
    return if book_id.nil?

    Book.transaction do
      candidate = Book.lock.find_by(id: book_id)
      next unless candidate
      next if candidate.acquisition_blocked?
      next if candidate.requests.exists? || candidate.owned_library_items.exists?
      next if OwnedMediaImport.exists?(created_book_id: candidate.id)
      next if candidate.owned_media_recovery_pending? || candidate.post_processing_recovery_pending?

      remaining_uploads = candidate.uploads
      remaining_uploads = remaining_uploads.where.not(id: excluding_upload_id) if excluding_upload_id
      next if remaining_uploads.exists?

      # Book's own destruction guards may still conservatively retain it.
      candidate.destroy
    end
  end

  def remove_unprocessed_file
    return if completed?
    return if file_path.blank?

    UploadImportFileService.discard_ingress!(file_path)
  end
end
