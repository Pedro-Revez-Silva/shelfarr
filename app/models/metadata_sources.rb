# frozen_string_literal: true

module MetadataSources
  NAMES = {
    "hardcover" => "Hardcover",
    "google_books" => "Google Books",
    "openlibrary" => "Open Library"
  }.freeze

  def self.display_name(source)
    NAMES.fetch(source.to_s, source.to_s.titleize)
  end
end