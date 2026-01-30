class Book < ApplicationRecord
  has_many :requests, dependent: :restrict_with_error
  has_many :uploads, dependent: :nullify

  enum :book_type, { audiobook: 0, ebook: 1 }

  validates :title, presence: true
  validates :book_type, presence: true

  scope :audiobooks, -> { where(book_type: :audiobook) }
  scope :ebooks, -> { where(book_type: :ebook) }
  scope :acquired, -> { where.not(file_path: nil) }
  scope :pending, -> { where(file_path: nil) }

  def acquired?
    file_path.present?
  end

  def display_name
    author.present? ? "#{title} by #{author}" : title
  end

  # Returns unified work_id in format "source:id"
  def unified_work_id
    if hardcover_id.present?
      "hardcover:#{hardcover_id}"
    elsif open_library_work_id.present?
      "openlibrary:#{open_library_work_id}"
    end
  end

  # Parse a work_id into [source, source_id]
  # Handles both prefixed ("hardcover:123") and legacy ("OL45804W") formats
  def self.parse_work_id(work_id)
    parts = work_id.to_s.split(":", 2)
    if parts.length == 2
      parts
    else
      # Legacy OpenLibrary IDs without prefix
      [ "openlibrary", work_id ]
    end
  end

  # Find a book by work_id and book_type
  def self.find_by_work_id(work_id, book_type:)
    source, source_id = parse_work_id(work_id)
    case source
    when "hardcover"
      find_by(hardcover_id: source_id, book_type: book_type)
    else
      find_by(open_library_work_id: source_id, book_type: book_type)
    end
  end

  # Find or initialize a book by work_id and book_type
  def self.find_or_initialize_by_work_id(work_id, book_type:)
    source, source_id = parse_work_id(work_id)
    case source
    when "hardcover"
      find_or_initialize_by(hardcover_id: source_id, book_type: book_type)
    else
      find_or_initialize_by(open_library_work_id: source_id, book_type: book_type)
    end
  end
end
