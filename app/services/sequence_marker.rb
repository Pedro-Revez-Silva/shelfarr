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

  # Digits may be glued ("Vol2", "T2", "T.2", "T02"). A full word needs a
  # separator before a roman numeral or spelled number, so "Buchi" and "parti"
  # are not volumes. T.II / T II still count. An apostrophe belongs to the
  # word, so a marker cannot start inside "Don't". A single letter that
  # continues as another initial ("C. G." / "C G") is not a roman numeral.
  # "T. C. Boyle" is an author initial, not tome 100.
  MARKER_TEMPLATE = <<~'PATTERN'
    (?<![A-Za-z]['`´’‘])
    \b
    (?:
      (?:%{words})(?:[\s.\-]*(?=\d)|(?:\s+|\s*[.\-]\s*))
      |
      t[\s.\-]*(?=\d)
      |
      t(?:\s+|\s*[.\-]\s*)(?=[ivxlcdm])(?![ivxlcdm][\s.\-_]+[a-z])
    )
    (%{number})
    \b
    (?!(?<=\b[ivxlcdm])(?:\.\s*|\s+)[a-z](?:\.|\s))
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

  # "#" and hyphens sit between a marker and its number ("Vol. #2", "Part-2",
  # "T.II"). Fold those marks into spaces before the number is read so a later
  # punctuation pass cannot delete the separator. Parentheses and brackets wrap
  # a year, so they are not separators. Underscores are TitleKey word breaks,
  # not letters, so they are folded before that pattern runs.
  SEPARATOR_PATTERN = Regexp.new(
    "\\b(#{WORD_ALTERNATION}|t)(?:\\s*[#.\\-]+\\s*)+(?=\\d|(?:#{ROMAN_NUMBER})\\b|(?:#{NUMBER_WORD})\\b)",
    Regexp::IGNORECASE
  ).freeze
  private_constant :SEPARATOR_PATTERN

  # TitleKey deletes these before tokenizing, so "Shakespeare's" and
  # "Shakespeares" are the same span.
  TITLE_QUOTE_CHARACTERS = /['"`´’‘]/
  private_constant :TITLE_QUOTE_CHARACTERS

  class << self
    def separate_marker_punctuation(text)
      text.to_s.tr("_", " ").gsub(SEPARATOR_PATTERN, "\\1 ")
    end

    # Author initials are not a volume ("Book C. G. Jung", "Book C Jung").
    # A credit that also appears inside the title is left there.
    def without_author_credit(title, author:, protected_title: nil)
      source = title.to_s
      protected_spans = phrase_spans(source, protected_title)
      author_spans = merge_spans(
        (phrase_spans(source, author) + initial_credit_spans(source, author)).reject { |span|
          protected_spans.any? { |protected_span| spans_overlap?(span, protected_span) }
        }
      )
      return source if author_spans.empty?

      masked = source.dup
      author_spans.reverse_each { |span| masked[span] = " " }
      masked
    end

    def neutralize(text)
      rewrite(separate_marker_punctuation(text))
    end

    # Marker words are replaced on text whose punctuation was already folded.
    def rewrite(text)
      apply(text, FULL_PATTERN) { |number| "#{NEUTRAL_MARKER} #{number}" }
    end

    # Drops the marker word and keeps the number, for indexer queries.
    # Number words stay put ("Book One") so a title is not reduced to "1".
    def strip(text)
      apply(separate_marker_punctuation(text), NUMERIC_PATTERN) { |number| number }
    end

    def numbers(text)
      found = []
      marker_text(separate_marker_punctuation(text.to_s)).scan(FULL_PATTERN) { found << normalize_number(Regexp.last_match(1)) }
      found
    end

    # The first number is the volume even when the other side also has a part.
    # Later numbers count only where both sides have them, so "Book 2" can
    # still meet "Book 2 Part 1".
    def conflict?(left, right)
      left_numbers = numbers(left)
      right_numbers = numbers(right)
      return false if left_numbers.empty? || right_numbers.empty?

      shared = [ left_numbers.size, right_numbers.size ].min
      shared.times.any? { |index| left_numbers[index] != right_numbers[index] }
    end

    private

    # Exact phrases keep an apostrophe as its own token ("Shakespeare.s"), so a
    # dotted release still protects the title's author.
    def phrase_spans(text, phrase)
      phrases = TitleKey.new(phrase.to_s).forms.map(&:split).reject(&:empty?)
      return [] if phrases.empty?

      tokens = normalized_source_tokens(text.to_s)
      spans = phrases.flat_map do |wanted|
        tokens.each_cons(wanted.length).filter_map do |window|
          next unless window.map(&:first) == wanted

          window.first[1]...window.last[2]
        end
      end
      spans.uniq
    end

    # "C G Jung" and "C. Jung" credit Carl Gustav Jung. Mask them before a
    # neighboring letter is read as a roman volume.
    def initial_credit_spans(text, author)
      parts = author.to_s.scan(/[[:alpha:]]+/)
      return [] if parts.size < 2

      surname = Regexp.escape(parts.last)
      initials = parts[0...-1].map { |part| Regexp.escape(part[0]) }
      patterns = [ full_initials_pattern(initials, surname) ]
      patterns << first_initial_pattern(initials.first, surname) if initials.size > 1

      spans = []
      patterns.each do |pattern|
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          span = char_offset(text, match.begin(0))...char_offset(text, match.end(0))
          spans << span unless spans.any? { |existing| spans_overlap?(existing, span) }
        end
      end
      spans
    end

    def full_initials_pattern(initials, surname)
      body = initials.map { |letter| "#{letter}\\.?" }.join("\\s*")
      /(?<![[:alnum:]])#{body}\s*#{surname}(?![[:alnum:]])/i
    end

    def first_initial_pattern(letter, surname)
      /(?<![[:alnum:]])#{letter}(?:[._]+\s*|\s+)#{surname}(?![[:alnum:]])/i
    end

    def merge_spans(spans)
      spans.sort_by(&:begin).each_with_object([]) do |span, merged|
        if merged.last && spans_overlap?(merged.last, span)
          merged[-1] = merged.last.begin...[ merged.last.end, span.end ].max
        else
          merged << span
        end
      end
    end

    # Source offsets survive quote folding so the span still covers "Shakespeare's".
    def normalized_source_tokens(text)
      folded = +""
      offsets = []
      text.each_char.with_index do |char, index|
        next if char.match?(TITLE_QUOTE_CHARACTERS)

        ActiveSupport::Inflector.transliterate(char).downcase.each_char do |out|
          folded << out
          offsets << index
        end
      end

      tokens = []
      folded.scan(/[a-z0-9]+/) do
        match = Regexp.last_match
        tokens << [
          TitleKey.new(match[0]).canonical,
          offsets[match.begin(0)],
          offsets[match.end(0) - 1] + 1
        ]
      end
      tokens
    end

    def spans_overlap?(left, right)
      left.begin < right.end && right.begin < left.end
    end

    def apply(text, pattern)
      source = text.to_s
      scan = marker_text(source)
      replacements = []
      scan.scan(pattern) do
        match = Regexp.last_match
        replacements << [
          char_offset(scan, match.begin(0)),
          char_offset(scan, match.end(0)),
          normalize_number(match[1])
        ]
      end

      result = source.dup
      replacements.reverse_each do |start_char, end_char, number|
        result[start_char...end_char] = yield(number)
      end
      result
    end

    # Same word breaks TitleKey uses for an exact phrase. The returned string
    # stays aligned with the source so only the marker span is rewritten.
    def marker_text(text)
      TitleKey.normalize_marker_boundaries(text.to_s)
    end

    def char_offset(text, byte_index)
      text.byteslice(0, byte_index).length
    end

    def normalize_number(value)
      token = value.to_s.downcase
      return token.to_i.to_s if token.match?(/\A\d+\z/)
      return NUMBER_WORDS.fetch(token) if NUMBER_WORDS.key?(token)

      ROMAN_VALUES.fetch(token)
    end
  end
end
