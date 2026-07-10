# frozen_string_literal: true

module ContentKinds
  BOOK = "book"
  GRAPHIC = "graphic"
  VALUES = [ BOOK, GRAPHIC ].freeze
  LEGACY_ALIASES = {
    "comic" => GRAPHIC,
    "manga" => GRAPHIC
  }.freeze

  module_function

  def normalize(value, default: BOOK)
    normalized = value.to_s.strip.downcase
    normalized = LEGACY_ALIASES.fetch(normalized, normalized)
    return normalized if VALUES.include?(normalized)
    return nil if default.nil?

    normalize(default, default: nil) || BOOK
  end

  def resolve(value, source_work_ids: [], collection_source: nil, default: BOOK)
    return GRAPHIC if collection_source.to_s == "comic_vine"
    return GRAPHIC if Array(source_work_ids).any? { |work_id| work_id.to_s.split(":", 2).first == "comic_vine" }

    normalize(value, default: default)
  end

  def graphic?(value)
    normalize(value, default: nil) == GRAPHIC
  end
end
