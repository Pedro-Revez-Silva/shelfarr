# frozen_string_literal: true

# Volume and part words from several languages, plus compact French tome
# numbers (T2, T.2, T02). A word counts only when a number or roman numeral
# follows it, so "Band of Brothers" and "parte" in prose stay ordinary words.
#
# One marker is rewritten to "volume N", so "Part 2" and "Tome 2" compare
# equal. Later markers stay "part N" in order, so "Tome 3 Partie 1" still
# conflicts with "Tome 3 Partie 2".
module SequenceMarkers
  WORDS = %w[
    book part vol volume
    tome partie livre
    band teil buch
    tomo parte libro livro volumen
    deel boek
  ].freeze
  NUMBER_WORDS = {
    "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5,
    "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10
  }.freeze
  # Letter runs such as "civil", "mix", or French "dix" can look like roman
  # numerals. Only a real numeral in a plausible volume range counts.
  MAX_ROMAN_VALUE = 200
  ROMAN_DIGIT_VALUES = {
    "i" => 1, "v" => 5, "x" => 10, "l" => 50, "c" => 100, "d" => 500, "m" => 1_000
  }.freeze
  ROMAN_NUMBER = /m{0,4}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})/
  private_constant :NUMBER_WORDS, :MAX_ROMAN_VALUE, :ROMAN_DIGIT_VALUES, :ROMAN_NUMBER

  WORD_ALTERNATION = WORDS.sort_by { |word| -word.length }.join("|")
  NUMBER_ALTERNATION = "\\d+|#{NUMBER_WORDS.keys.join("|")}|[ivxlcdm]+"
  MARKER_PATTERN = Regexp.new(
    "\\bT(?:\\.\\s*)?0*(\\d+)\\b|\\b(?:#{WORD_ALTERNATION})\\.?\\s*(#{NUMBER_ALTERNATION})\\b",
    Regexp::IGNORECASE
  ).freeze
  private_constant :WORD_ALTERNATION, :NUMBER_ALTERNATION, :MARKER_PATTERN

  module_function

  def normalize(text)
    rewrite(text) { |number, index| index.zero? ? "volume #{number}" : "part #{number}" }
  end

  def strip(text)
    rewrite(text) { |number, _index| " #{number} " }
  end

  def conflict?(left, right)
    left_numbers = marker_numbers(left)
    right_numbers = marker_numbers(right)
    return false if left_numbers.empty? || right_numbers.empty?

    left_numbers.zip(right_numbers).any? do |left_number, right_number|
      !right_number.nil? && left_number != right_number
    end
  end

  def rewrite(text)
    source = text.to_s
    matches = marker_matches(source)
    return squish(source) if matches.empty?

    rewritten = +""
    cursor = 0
    matches.each_with_index do |match, index|
      rewritten << source[cursor...match.begin(0)]
      rewritten << yield(marker_number(match), index)
      cursor = match.end(0)
    end
    rewritten << source[cursor..]
    squish(rewritten)
  end
  private_class_method :rewrite

  def marker_matches(text)
    matches = []
    cursor = 0
    while (match = MARKER_PATTERN.match(text, cursor))
      break if match.end(0) <= cursor

      if valid_number?(match[1] || match[2])
        matches << match
        cursor = match.end(0)
      else
        cursor = match.begin(0) + 1
      end
    end
    matches
  end
  private_class_method :marker_matches

  def marker_numbers(text)
    marker_matches(text.to_s).map { |match| marker_number(match) }
  end
  private_class_method :marker_numbers

  def marker_number(match)
    normalize_number(match[1] || match[2])
  end
  private_class_method :marker_number

  def valid_number?(value)
    token = value.to_s
    return false if token.empty?
    return true if token.match?(/\A\d+\z/i)
    return true if NUMBER_WORDS.key?(token.downcase)

    valid_roman?(token)
  end
  private_class_method :valid_number?

  def valid_roman?(token)
    return false unless token.match?(/\A#{ROMAN_NUMBER.source}\z/i)

    roman_to_integer(token.downcase).between?(1, MAX_ROMAN_VALUE)
  end
  private_class_method :valid_roman?

  def normalize_number(value)
    token = value.to_s.downcase
    return token.to_i.to_s if token.match?(/\A\d+\z/)
    return NUMBER_WORDS.fetch(token).to_s if NUMBER_WORDS.key?(token)

    roman_to_integer(token).to_s
  end
  private_class_method :normalize_number

  def roman_to_integer(value)
    total = 0
    previous = 0
    value.each_char.reverse_each do |character|
      current = ROMAN_DIGIT_VALUES.fetch(character)
      total += current < previous ? -current : current
      previous = [ previous, current ].max
    end
    total
  end
  private_class_method :roman_to_integer

  def squish(text)
    text.gsub(/\s+/, " ").strip
  end
  private_class_method :squish
end
