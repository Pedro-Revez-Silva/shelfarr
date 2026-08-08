# frozen_string_literal: true

module MetadataSources
  HARDCOVER_BOOK_ID_PATTERN = /\A[1-9]\d*\z/

  NAMES = {
    "hardcover" => "Hardcover",
    "google_books" => "Google Books",
    "openlibrary" => "Open Library",
    "comic_vine" => "Comic Vine"
  }.freeze

  def self.display_name(source)
    NAMES.fetch(source.to_s, source.to_s.titleize)
  end

  def self.hardcover_book_url(id)
    id = id.to_s
    "https://hardcover.app/id/book/#{id}" if HARDCOVER_BOOK_ID_PATTERN.match?(id)
  end
end
