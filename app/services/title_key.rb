# frozen_string_literal: true

class TitleKey
  ROMAN_NUMBER_TOKENS = {
    "II" => "2",
    "III" => "3",
    "IV" => "4",
    "V" => "5",
    "VI" => "6",
    "VII" => "7",
    "VIII" => "8",
    "IX" => "9",
    "X" => "10",
    "XI" => "11",
    "XII" => "12",
    "XIII" => "13",
    "XIV" => "14",
    "XV" => "15"
  }.freeze

  # Quotes are removed before transliteration, which would otherwise turn
  # curly apostrophes into "?". Apostrophes specifically can also be a word
  # break; that form is kept only for exact title phrases.
  QUOTE_CHARACTERS = "'\"`´’‘"
  APOSTROPHE_PATTERN = /['`´’‘]/
  private_constant :QUOTE_CHARACTERS, :APOSTROPHE_PATTERN, :ROMAN_NUMBER_TOKENS

  def initialize(text)
    @text = text.to_s
  end

  def canonical
    @canonical ||= number_tokens(spaced)
  end

  def stripped
    @stripped ||= number_tokens(collapsed)
  end

  def spaced
    @spaced ||= tokenize(without_quotes(@text))
  end

  def collapsed
    @collapsed ||= punctuationless(without_quotes(@text))
  end

  def forms
    @forms ||= (substring_forms + apostrophe_forms).compact_blank.uniq
  end

  def substring_forms
    @substring_forms ||= [ canonical, stripped ].compact_blank.uniq
  end

  def short?
    canonical.length < 4
  end

  # Exact phrases split on every non-letter, including underscores. Marker
  # parsing keeps apostrophes, wrapped years, and dots, so "Don't" stays one
  # word, "(1894)" is not a volume, and "C. G." is not a roman numeral.
  def self.normalize_boundaries(text, preserve: "")
    text.to_s.gsub(/[^A-Za-z0-9]/) { |char| preserve.include?(char) ? char : " " }
  end

  def self.normalize_marker_boundaries(text)
    normalize_boundaries(text, preserve: "#{QUOTE_CHARACTERS}()[].")
  end

  private

  def apostrophe_forms
    return [] unless @text.match?(APOSTROPHE_PATTERN)

    [ number_tokens(tokenize(without_quotes(@text.gsub(APOSTROPHE_PATTERN, " ")))) ]
  end

  def without_quotes(text)
    text.delete(QUOTE_CHARACTERS)
  end

  def tokenize(text)
    fold_scripts(text).gsub(/[^\p{L}\p{N}]/, " ").squish
  end

  def punctuationless(text)
    fold_scripts(text).gsub(/[^\p{L}\p{N}\s]/, "").squish
  end

  # "ü" becomes "u", but Cyrillic and Han have no approximation. Keeping
  # those letters avoids an empty key that cannot match the release name.
  def fold_scripts(text)
    text.to_s.each_char.map { |char| fold_character(char) }.join.downcase
  end

  def fold_character(char)
    transliterated = ActiveSupport::Inflector.transliterate(char, "")
    return transliterated if transliterated.match?(/[A-Za-z0-9]/)
    return char if char.match?(/[\p{L}\p{N}]/)

    # A decomposed "ü" is "u" plus a mark. Dropping the mark keeps it equal to "u".
    char.match?(/\p{M}/) ? "" : char
  end

  def number_tokens(text)
    text.split.map { |token| ROMAN_NUMBER_TOKENS.fetch(token.upcase, token) }.join(" ")
  end
end
