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

  def remove_unprocessed_file
    return if completed?
    return if file_path.blank?

    UploadImportFileService.discard_ingress!(file_path)
  end
end
