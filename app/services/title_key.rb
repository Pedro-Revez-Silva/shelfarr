# frozen_string_literal: true

class TitleKey
  # Zeros of every Unicode decimal-digit block. The next nine code points are
  # digits 1-9, and the blocks do not overlap.
  DECIMAL_DIGIT_ZERO = [
    0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6,
    0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0,
    0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
    0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900,
    0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0, 0x10D30, 0x11066,
    0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0, 0x11650,
    0x116C0, 0x11730, 0x118E0, 0x11950, 0x11C50, 0x11D50, 0x11DA0,
    0x11F50, 0x16A60, 0x16AC0, 0x16B50, 0x1D7CE, 0x1D7D8, 0x1D7E2,
    0x1D7EC, 0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E950, 0x1FBF0
  ].freeze

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

  # Quotes and apostrophes are removed before folding. An apostrophe can also
  # split a word; that form is kept only for exact title phrases. U+02BB and
  # U+02BC are modifier letters, so NFKC leaves them inside a name
  # ("OʼConnor") unless they are removed with the other apostrophes.
  APOSTROPHE_CHARACTERS = "`'´’‘\u02BB\u02BC"
  QUOTE_CHARACTERS = "#{APOSTROPHE_CHARACTERS}\""
  APOSTROPHE_PATTERN = /[#{APOSTROPHE_CHARACTERS}]/
  private_constant :APOSTROPHE_CHARACTERS, :QUOTE_CHARACTERS, :APOSTROPHE_PATTERN, :ROMAN_NUMBER_TOKENS,
    :DECIMAL_DIGIT_ZERO

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
  # letters and numerals count, so a Cyrillic word is not discarded and "Ⅱ"
  # stays attached to a title. Marker parsing keeps apostrophes, wrapped
  # years, and dots, so "Don't" stays one word, "(1894)" is not a volume,
  # and "C. G." is not a roman numeral.
  def self.normalize_boundaries(text, preserve: "")
    text.to_s.gsub(/[^\p{L}\p{N}]/) { |char| preserve.include?(char) ? char : " " }
  end

  def self.normalize_marker_boundaries(text)
    normalize_boundaries(text, preserve: "#{QUOTE_CHARACTERS}()[].")
  end

  # "?" means the transliterator has no ASCII approximation. Keep that letter
  # so Cyrillic and CJK stay searchable. Accented Latin still folds ("ß" -> "ss").
  # NFKC composes "ü" and rewrites a compatibility numeral ("Ⅱ" -> "II").
  # Casefold maps final sigma ("ς") onto "σ". Decimal digits from other
  # scripts ("٢", "２") become ASCII before anything classifies a numeral.
  def self.fold(text)
    normalize_decimal_digits(text).tr("ёЁ", "еЕ").gsub(/[^\x00-\x7F]/) { |char|
      transliterated = ActiveSupport::Inflector.transliterate(char)
      transliterated == "?" ? char : transliterated
    }.downcase(:fold)
  end

  # Nd digits are ten code points starting at a script's zero. NFKC already
  # turns compatibility digits (fullwidth "２") into ASCII; the rest stay Nd.
  def self.normalize_decimal_digits(text)
    text.to_s.unicode_normalize(:nfkc).gsub(/\p{Nd}/) { |char|
      ascii_decimal_digit(char) || char
    }
  end

  def self.quote_character?(character)
    QUOTE_CHARACTERS.include?(character)
  end

  def self.ascii_decimal_digit(char)
    ordinal = char.ord
    DECIMAL_DIGIT_ZERO.each do |zero|
      offset = ordinal - zero
      return offset.to_s if offset.between?(0, 9)
    end
    nil
  end
  private_class_method :ascii_decimal_digit

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
    self.class.fold(text).gsub(/[^\p{L}\p{N}\s]/, "").squish
  end

  def number_tokens(text)
    text.split.map { |token| ROMAN_NUMBER_TOKENS.fetch(token.upcase, token) }.join(" ")
  end
end
