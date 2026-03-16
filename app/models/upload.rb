# frozen_string_literal: true

class Upload < ApplicationRecord
  belongs_to :user
  belongs_to :book, optional: true

  enum :status, {
    pending: 0,
    processing: 1,
    completed: 2,
    failed: 3
  }

  enum :book_type, { audiobook: 0, ebook: 1 }

  # Supported file extensions
  AUDIOBOOK_EXTENSIONS = %w[m4b mp3 zip rar].freeze
  EBOOK_EXTENSIONS = %w[epub pdf mobi azw3].freeze
  SUPPORTED_EXTENSIONS = (AUDIOBOOK_EXTENSIONS + EBOOK_EXTENSIONS).freeze

  validates :original_filename, presence: true
  validates :status, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :pending_or_processing, -> { where(status: [:pending, :processing]) }
  scope :for_user, ->(user) { where(user: user) }

  def file_extension
    File.extname(original_filename).delete(".").downcase
  end

  def audiobook_file?
    AUDIOBOOK_EXTENSIONS.include?(file_extension)
  end

  def ebook_file?
    EBOOK_EXTENSIONS.include?(file_extension)
  end

  def archive_file?
    %w[zip rar].include?(file_extension)
  end

  def infer_book_type
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
end
