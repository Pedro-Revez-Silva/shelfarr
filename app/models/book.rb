class Book < ApplicationRecord
  METADATA_SOURCE_NAMES = MetadataSources::NAMES

  has_many :requests, dependent: :restrict_with_error
  has_many :uploads, dependent: :nullify
  has_many :owned_library_items, dependent: :nullify

  before_destroy :prevent_destroy_during_active_acquisition, prepend: true

  enum :book_type, { audiobook: 0, ebook: 1, comicbook: 2 }
  enum :content_kind, { book: 0, graphic: 1 }, prefix: :content

  validates :title, presence: true
  validates :book_type, presence: true
  validates :acquisition_reservation_owner_type,
    :acquisition_reservation_owner_id,
    presence: true,
    if: :acquisition_reserved?

  scope :audiobooks, -> { where(book_type: :audiobook) }
  scope :ebooks, -> { where(book_type: :ebook) }
  scope :comicbooks, -> { where(book_type: :comicbook) }
  scope :acquired, -> { where.not(file_path: nil).where("TRIM(file_path) <> ''") }
  scope :pending, -> { where(file_path: nil) }
  scope :acquisition_reserved, -> { where.not(acquisition_reservation_token: nil) }

  def acquired?
    file_path.present?
  end

  def acquisition_reserved?
    acquisition_reservation_token.present?
  end

  def acquisition_blocked?
    acquired? || acquisition_reserved?
  end

  def owned_media_recovery_pending?
    return false unless persisted?

    upload_ids = uploads.select(:id)
    created_book_imports = OwnedMediaImport.cancellation_blocking.where(created_book_id: id)
    upload_book_imports = OwnedMediaImport.cancellation_blocking.where(upload_id: upload_ids)
    created_book_imports.or(upload_book_imports).exists?
  end

  # Post-processing publishes library bytes before it can atomically attach
  # their path to this Book and complete the Request. Keep the Book record (and
  # therefore its recovery graph) alive while any non-completed Request owns
  # that recoverable publication. Completed legacy requests are excluded
  # because older Shelfarr versions did not clear successful owner IDs.
  def post_processing_recovery_pending?
    return false unless persisted?

    cleanup_pending = requests
      .joins(:downloads)
      .merge(Download.completed.where.not(post_processing_cleanup_state: [ nil, "" ]))
      .exists?
    return true if cleanup_pending

    requests
      .where.not(status: Request.statuses[:completed])
      .joins(:downloads)
      .merge(Download.completed.where.not(post_processing_job_id: [ nil, "" ]))
      .exists?
  end

  def display_name
    author.present? ? "#{title} by #{author}" : title
  end

  def metadata_source_name
    return nil if unified_work_id.blank?

    source, = Book.parse_work_id(unified_work_id)
    MetadataSources.display_name(source)
  end

  def metadata_source_url
    return nil if unified_work_id.blank?

    source, source_id = Book.parse_work_id(unified_work_id)
    return nil if source_id.blank?

    case source
    when "hardcover"
      "https://hardcover.app/books/#{source_id}"
    when "google_books"
      "https://books.google.com/books?id=#{source_id}"
    when "openlibrary"
      "https://openlibrary.org/works/#{source_id}"
    when "comic_vine"
      if source_id.to_s.start_with?("4000-")
        "https://comicvine.gamespot.com/issue/#{source_id}/"
      else
        "https://comicvine.gamespot.com/volume/#{source_id}/"
      end
    end
  end

  def book_type_label
    case book_type
    when "audiobook" then "Audiobook"
    when "ebook" then "Ebook"
    when "comicbook" then "Comics & Manga"
    else
      book_type.to_s.titleize
    end
  end

  def metadata_source_attribution
    return nil if metadata_source_name.blank?

    "Metadata from #{metadata_source_name}"
  end

  # Returns unified work_id in format "source:id"
  def unified_work_id
    if hardcover_id.present?
      "hardcover:#{hardcover_id}"
    elsif google_books_id.present?
      "google_books:#{google_books_id}"
    elsif comic_vine_id.present?
      "comic_vine:#{comic_vine_id}"
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
    when "google_books"
      find_by(google_books_id: source_id, book_type: book_type)
    when "comic_vine"
      find_by(comic_vine_id: source_id, book_type: book_type)
    else
      find_by(open_library_work_id: source_id, book_type: book_type)
    end
  end

  def self.find_by_any_work_id(work_ids, book_type:)
    find_in_lookup(preload_by_work_ids(work_ids), work_ids, book_type: book_type)
  end

  def self.find_in_lookup(lookup, work_ids, book_type:)
    Array(work_ids).each do |work_id|
      source, source_id = parse_work_id(work_id)
      lookup_keys = [ work_id.to_s, "#{source}:#{source_id}" ].uniq
      book = lookup_keys.filter_map { |key| lookup.dig(key, book_type.to_s) }.first
      return book if book
    end

    nil
  end

  def self.preload_by_work_ids(work_ids)
    ids = Array(work_ids).compact_blank.map(&:to_s).uniq
    return {} if ids.empty?

    hardcover_ids = []
    google_books_ids = []
    comic_vine_ids = []
    openlibrary_ids = []

    ids.each do |work_id|
      source, source_id = parse_work_id(work_id)
      next if source_id.blank?

      case source
      when "hardcover"
        hardcover_ids << source_id
      when "google_books"
        google_books_ids << source_id
      when "comic_vine"
        comic_vine_ids << source_id
      else
        openlibrary_ids << source_id
      end
    end

    scope = none
    scope = scope.or(where(hardcover_id: hardcover_ids)) if hardcover_ids.any?
    scope = scope.or(where(google_books_id: google_books_ids)) if google_books_ids.any?
    scope = scope.or(where(comic_vine_id: comic_vine_ids)) if comic_vine_ids.any?
    scope = scope.or(where(open_library_work_id: openlibrary_ids)) if openlibrary_ids.any?

    lookup = Hash.new { |hash, key| hash[key] = {} }
    scope.includes(:requests).find_each do |book|
      work_ids_for(book).each do |unified_work_id|
        lookup[unified_work_id][book.book_type] = book

        source, source_id = parse_work_id(unified_work_id)
        lookup[source_id][book.book_type] = book if source == "openlibrary"
      end
    end

    lookup
  end

  def self.work_ids_for(book)
    [
      ("hardcover:#{book.hardcover_id}" if book.hardcover_id.present?),
      ("google_books:#{book.google_books_id}" if book.google_books_id.present?),
      ("comic_vine:#{book.comic_vine_id}" if book.comic_vine_id.present?),
      ("openlibrary:#{book.open_library_work_id}" if book.open_library_work_id.present?)
    ].compact
  end

  # Find or initialize a book by work_id and book_type
  def self.find_or_initialize_by_work_id(work_id, book_type:)
    source, source_id = parse_work_id(work_id)
    case source
    when "hardcover"
      find_or_initialize_by(hardcover_id: source_id, book_type: book_type)
    when "google_books"
      find_or_initialize_by(google_books_id: source_id, book_type: book_type)
    when "comic_vine"
      find_or_initialize_by(comic_vine_id: source_id, book_type: book_type)
    else
      find_or_initialize_by(open_library_work_id: source_id, book_type: book_type)
    end
  end

  def assign_work_id(work_id)
    source, source_id = self.class.parse_work_id(work_id)
    return if source_id.blank?

    case source
    when "hardcover"
      self.hardcover_id ||= source_id
    when "google_books"
      self.google_books_id ||= source_id
    when "comic_vine"
      self.comic_vine_id ||= source_id
    else
      self.open_library_work_id ||= source_id
    end
  end

  private

  def prevent_destroy_during_active_acquisition
    message = if acquisition_reserved?
      "An acquisition still owns a recovery reservation for this book"
    elsif owned_media_recovery_pending?
      "An Audible backup still owns recovery state for this book"
    elsif post_processing_recovery_pending?
      "A completed download still owns recoverable post-processing for this book"
    end
    return unless message

    errors.add(:base, message)
    throw :abort
  end
end
