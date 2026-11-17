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

  # Exact phrases split on every non-letter, including underscores. Unicode
  # letters count, so a Cyrillic word is not discarded as punctuation. Marker
  # parsing keeps apostrophes, wrapped years, and dots, so "Don't" stays one
  # word, "(1894)" is not a volume, and "C. G." is not a roman numeral.
  def self.normalize_boundaries(text, preserve: "")
    text.to_s.gsub(/[^\p{L}\p{Nd}]/) { |char| preserve.include?(char) ? char : " " }
  end

  def self.normalize_marker_boundaries(text)
    normalize_boundaries(text, preserve: "#{QUOTE_CHARACTERS}()[].")
  end

  # "?" means the transliterator has no ASCII approximation. Keep that letter
  # so Cyrillic and CJK stay searchable. Accented Latin still folds ("ß" -> "ss").
  # NFC runs first so a decomposed "u" + diaeresis folds like "ü".
  def self.fold(text)
    text.to_s.unicode_normalize(:nfc).gsub(/[^\x00-\x7F]/) { |char|
      transliterated = ActiveSupport::Inflector.transliterate(char)
      transliterated == "?" ? char : transliterated
    }.downcase
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
    self.class.normalize_boundaries(self.class.fold(text)).squish
  end

  def punctuationless(text)
    self.class.fold(text).gsub(/[^\p{L}\p{Nd}\s]/, "").squish
  end

  def number_tokens(text)
    text.split.map { |token| ROMAN_NUMBER_TOKENS.fetch(token.upcase, token) }.join(" ")
  end
end
