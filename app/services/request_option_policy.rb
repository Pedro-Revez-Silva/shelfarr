# frozen_string_literal: true

class RequestOptionPolicy
  BOOK_TYPES_BY_CONTENT_KIND = {
    "book" => %w[audiobook ebook].freeze,
    "graphic" => %w[comicbook].freeze
  }.freeze

  class << self
    def book_types_for(content_kind)
      if ContentKinds.graphic?(content_kind)
        BOOK_TYPES_BY_CONTENT_KIND.fetch("graphic")
      else
        BOOK_TYPES_BY_CONTENT_KIND.fetch("book")
      end
    end

    alias_method :allowed_book_types, :book_types_for

    def permitted_book_types?(book_types, content_kind)
      Array(book_types).all? { |book_type| book_types_for(content_kind).include?(book_type.to_s) }
    end

    def incompatible_book_types(book_types, content_kind)
      Array(book_types).map(&:to_s) - book_types_for(content_kind)
    end

    def book_type_label(book_type)
      case book_type.to_s
      when "audiobook" then "Audiobook"
      when "ebook" then "Ebook"
      when "comicbook" then "Comics & Manga"
      else book_type.to_s.humanize
      end
    end

    def content_kind_label(content_kind)
      ContentKinds.graphic?(content_kind) ? "Comics & Manga" : "book"
    end
  end
end
