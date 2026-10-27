# frozen_string_literal: true

# Volume words in a few languages are the same sequence when the number matches.
# A word counts only when a number follows it directly, so "Band of Brothers"
# and a bare "parte" stay ordinary prose.
class SequenceMarker
  # en: book, part, vol, volume
  # fr: tome, partie, livre (T2 / T.2 / T02 is the abbreviation below)
  # de: band, teil, buch
  # es/it/pt: tomo, parte, libro, livro, volumen
  # nl: deel, boek
  MARKER_WORDS = %w[
    book part vol volume
    tome partie livre
    band teil buch
    tomo parte libro livro volumen
    deel boek
  ].freeze
  NEUTRAL_MARKER = "volume"
  NUMBER_WORDS = {
    "one" => "1", "two" => "2", "three" => "3", "four" => "4", "five" => "5",
    "six" => "6", "seven" => "7", "eight" => "8", "nine" => "9", "ten" => "10"
  }.freeze
  ROMAN_GLYPHS = {
    100 => "c", 90 => "xc", 50 => "l", 40 => "xl", 10 => "x", 9 => "ix", 5 => "v", 4 => "iv", 1 => "i"
  }.freeze
  # Canonical forms only, so "mix" or "did" is not a volume number.
  ROMAN_VALUES = (1..100).each_with_object({}) { |number, table|
    remaining = number
    roman = +""
    ROMAN_GLYPHS.each do |value, glyph|
      while remaining >= value
        roman << glyph
        remaining -= value
      end
    end
    table[roman] = number.to_s
  }.freeze

  WORD_ALTERNATION = MARKER_WORDS.sort_by { |word| -word.length }.join("|").freeze
  ROMAN_NUMBER = ROMAN_VALUES.keys.sort_by { |token| -token.length }.join("|").freeze
  NUMBER_WORD = NUMBER_WORDS.keys.join("|").freeze
  NUMERIC_NUMBER = "0*\\d+|#{ROMAN_NUMBER}"
  ANY_NUMBER = "#{NUMERIC_NUMBER}|#{NUMBER_WORD}"
  private_constant :WORD_ALTERNATION, :ROMAN_NUMBER, :NUMBER_WORD, :NUMERIC_NUMBER, :ANY_NUMBER,
    :ROMAN_VALUES, :ROMAN_GLYPHS

  # Digits may be glued ("Vol2", "T2"). Roman numerals and number words need a
  # separator, so "parti" and "tim" are not volumes. T.II / T II still count.
  MARKER_TEMPLATE = <<~'PATTERN'
    \b
    (?:
      (?:%{words})(?:[\s.\-]*(?=\d)|(?:\s+|\s*[.\-]\s*))
      |
      t[\s.\-]*(?=\d)
      |
      t(?:\s+|\s*[.\-]\s*)(?=[ivxlcdm])
    )
    (%{number})
    \b
  PATTERN
  FULL_PATTERN = Regexp.new(
    format(MARKER_TEMPLATE, words: WORD_ALTERNATION, number: ANY_NUMBER),
    Regexp::IGNORECASE | Regexp::EXTENDED
  ).freeze
  NUMERIC_PATTERN = Regexp.new(
    format(MARKER_TEMPLATE, words: WORD_ALTERNATION, number: NUMERIC_NUMBER),
    Regexp::IGNORECASE | Regexp::EXTENDED
  ).freeze
  private_constant :MARKER_TEMPLATE, :FULL_PATTERN, :NUMERIC_PATTERN

  class << self
    def neutralize(text)
      rewrite(text, FULL_PATTERN) { |number| "#{NEUTRAL_MARKER} #{number}" }
    end

    # Drops the marker word and keeps the number, for indexer queries.
    # Number words stay put ("Book One") so a title is not reduced to "1".
    def strip(text)
      rewrite(text, NUMERIC_PATTERN) { |number| number }
    end

    def numbers(text)
      found = []
      text.to_s.scan(FULL_PATTERN) { found << normalize_number(Regexp.last_match(1)) }
      found
    end

    # One number on each side: marker words are interchangeable.
    # Two or more on both: every number has to match, so "Tome 3 Partie 1"
    # stays distinct from "Tome 3 Partie 2". A lone "Book 2" can still meet
    # "Book 2 Part 1"; that extra part is not a second number on both sides.
    def conflict?(left, right)
      left_numbers = numbers(left)
      right_numbers = numbers(right)
      return false if left_numbers.empty? || right_numbers.empty?
      return left_numbers != right_numbers if left_numbers.size > 1 && right_numbers.size > 1
      return false unless left_numbers.size == 1 && right_numbers.size == 1

      left_numbers != right_numbers
    end

    private

    def rewrite(text, pattern)
      text.to_s.gsub(pattern) { yield normalize_number(Regexp.last_match(1)) }
    end

    def normalize_number(value)
      token = value.to_s.downcase
      return token.to_i.to_s if token.match?(/\A\d+\z/)
      return NUMBER_WORDS.fetch(token) if NUMBER_WORDS.key?(token)

      ROMAN_VALUES.fetch(token)
    end
  end
end
