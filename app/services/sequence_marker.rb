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
    1000 => "m", 900 => "cm", 500 => "d", 400 => "cd",
    100 => "c", 90 => "xc", 50 => "l", 40 => "xl", 10 => "x", 9 => "ix", 5 => "v", 4 => "iv", 1 => "i"
  }.freeze
  # Standard canonical forms through 3999, excluding words used as prose in
  # the marker languages. Keep those words ordinary in every capitalization.
  AMBIGUOUS_ROMAN_WORDS = %w[di dix mi mix].freeze
  ROMAN_VALUES = (1..3999).each_with_object({}) { |number, table|
    remaining = number
    roman = +""
    ROMAN_GLYPHS.each do |value, glyph|
      while remaining >= value
        roman << glyph
        remaining -= value
      end
    end
    table[roman] = number.to_s unless AMBIGUOUS_ROMAN_WORDS.include?(roman)
  }.freeze

  WORD_ALTERNATION = MARKER_WORDS.sort_by { |word| -word.length }.join("|").freeze
  ROMAN_NUMBER = ROMAN_VALUES.keys.sort_by { |token| -token.length }.join("|").freeze
  NUMBER_WORD = NUMBER_WORDS.keys.join("|").freeze
  NUMERIC_NUMBER = "0*\\d+|#{ROMAN_NUMBER}"
  ANY_NUMBER = "#{NUMERIC_NUMBER}|#{NUMBER_WORD}"
  # Release words after an abbreviated roman marker ("T V FR", "T V Partie").
  # Language tokens come from the release parser, so codes and names stay one list.
  FORMAT_WORDS = %w[
    epub pdf mobi azw azw3 ebook audiobook m4b mp3 flac cbr cbz retail multi
  ].freeze
  FOLLOWER_WORDS = (MARKER_WORDS + ReleaseParserService.language_tokens + FORMAT_WORDS).uniq.freeze
  FOLLOWER_ALTERNATION = FOLLOWER_WORDS.sort_by { |word| -word.length }.map { |word|
    Regexp.escape(word)
  }.join("|").freeze
  GLUED_VOLUME_PATTERN = /\A(?:#{WORD_ALTERNATION}|t)(0*\d+)\z/
  private_constant :WORD_ALTERNATION, :ROMAN_NUMBER, :NUMBER_WORD, :NUMERIC_NUMBER, :ANY_NUMBER,
    :ROMAN_VALUES, :ROMAN_GLYPHS, :AMBIGUOUS_ROMAN_WORDS, :FORMAT_WORDS, :FOLLOWER_WORDS, :FOLLOWER_ALTERNATION,
    :GLUED_VOLUME_PATTERN

  # Digits may be glued ("Vol2", "T2", "T.2", "T02"). A full word needs a
  # separator before a roman numeral or spelled number, so "Buchi" and "parti"
  # are not volumes. T.II / T II still count. An apostrophe belongs to the
  # word, so a marker cannot start inside "Don't". A dotted initial followed
  # by a spaced surname ("C. G. Jung", "C.G. Jung") is not a roman numeral.
  # A scene dot is only a word break, so "Book.V.A.Novel" is still volume 5.
  # "T. C. Boyle" is an author initial, not tome 100. A part label, release
  # word, or language token after "T V" is still a volume.
  MARKER_TEMPLATE = <<~'PATTERN'
    (?<![A-Za-z]['`´’‘])
    \b
    (?:
      (?:%{words})(?:[\s.\-]*(?=\d)|(?:\s+|\s*[.\-]\s*))
      |
      t[\s.\-]*(?=\d)
      |
      t(?:\s+|\s*[.\-]\s*)(?=[ivxlcdm])(?![ivxlcdm][\s.\-_]+(?!(?:%{followers})\b)[a-z])
    )
    (%{number})
    \b
    (?!(?<=\b[ivxlcdm])(?:\.\s*|\s+)[a-z]\.(?:\s*[a-z]\.)*\s+[a-z])
  PATTERN
  FULL_PATTERN = Regexp.new(
    format(MARKER_TEMPLATE, words: WORD_ALTERNATION, number: ANY_NUMBER, followers: FOLLOWER_ALTERNATION),
    Regexp::IGNORECASE | Regexp::EXTENDED
  ).freeze
  NUMERIC_PATTERN = Regexp.new(
    format(MARKER_TEMPLATE, words: WORD_ALTERNATION, number: NUMERIC_NUMBER, followers: FOLLOWER_ALTERNATION),
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

    # Exact phrases keep an apostrophe as its own token ("Shakespeare.s").
    # Marker words are compared after sequence normalization ("Band" / "Volume")
    # and the span stays on the source text.
    def phrase_spans(text, phrase)
      phrases = sequence_phrase_forms(phrase)
      return [] if phrases.empty?

      tokens = sequence_normalized_source_tokens(text.to_s)
      spans = phrases.flat_map do |wanted|
        tokens.each_cons(wanted.length).filter_map do |window|
          next unless window.map(&:first) == wanted

          window.first[1]...window.last[2]
        end
      end
      spans.uniq
    end

    def sequence_phrase_forms(phrase)
      TitleKey.new(phrase.to_s).forms.filter_map do |form|
        normalize_marker_tokens(form.split).presence
      end
    end

    def sequence_normalized_source_tokens(text)
      normalize_marker_tokens(normalized_source_tokens(text))
    end

    def normalize_marker_tokens(tokens)
      result = []
      index = 0
      while index < tokens.length
        current = tokens[index]
        nxt = tokens[index + 1]
        following = tokens[index + 2]
        if nxt && volume_token_pair?(current, nxt, following)
          result << token_with_text("volume", current)
          result << token_with_text(normalize_number(token_raw(nxt)), nxt)
          index += 2
        elsif (number = glued_volume_number(token_raw(current)))
          result << token_with_text("volume", current)
          result << token_with_text(number, current)
          index += 1
        else
          result << token_with_text(token_compare(current), current)
          index += 1
        end
      end
      result
    end

    def volume_token_pair?(word_token, number_token, following_token)
      word = token_raw(word_token)
      number = token_raw(number_token)
      return false unless volume_number_token?(number)

      if word == "t"
        return false unless roman_or_digit?(number)
        return false if single_roman_letter?(number) && author_initial_follower?(token_raw(following_token))
      else
        return false unless MARKER_WORDS.include?(word)
        return false if single_roman_letter?(number) && initial_continuation?(following_token)
      end

      true
    end

    # The next letter is an initial when it carries a dot ("C. G.", "C.G.", "C G.").
    # "Book V A Novel" does not, so the numeral stays a volume.
    def initial_continuation?(following_token)
      another_initial?(token_raw(following_token)) && trailing_dot?(following_token)
    end

    def trailing_dot?(token)
      token.is_a?(Array) && token[4]
    end

    def author_initial_follower?(following)
      another_initial?(following) || author_credit_word?(following)
    end

    def another_initial?(following)
      following.to_s.match?(/\A[a-z]\z/)
    end

    def author_credit_word?(following)
      return false if following.blank? || !following.match?(/\A[a-z]/)

      !FOLLOWER_WORDS.include?(following)
    end

    def volume_number_token?(token)
      roman_or_digit?(token) || NUMBER_WORDS.key?(token)
    end

    def roman_or_digit?(token)
      token.match?(/\A\d+\z/) || ROMAN_VALUES.key?(token)
    end

    def single_roman_letter?(token)
      token.length == 1 && ROMAN_VALUES.key?(token)
    end

    def glued_volume_number(token)
      match = token.match(GLUED_VOLUME_PATTERN)
      normalize_number(match[1]) if match
    end

    def token_raw(token)
      token.is_a?(Array) ? token[3] : token
    end

    def token_compare(token)
      token.is_a?(Array) ? token[0] : token
    end

    def token_with_text(text, token)
      token.is_a?(Array) ? [ text, token[1], token[2] ] : text
    end

    # "C G Jung" and "C. Jung" credit Carl Gustav Jung. A catalog name can
    # omit middle initials the release still prints ("Carl Jung" / "C G Jung").
    # Mask the credit before a neighboring letter is read as a roman volume.
    def initial_credit_spans(text, author)
      parts = author.to_s.scan(/[[:alpha:]]+/)
      return [] if parts.size < 2

      surname = Regexp.escape(parts.last)
      initials = parts[0...-1].map { |part| Regexp.escape(part[0]) }
      patterns = [ full_initials_pattern(initials, surname), extra_middle_initials_pattern(initials.first, surname) ]
      patterns << first_initial_pattern(initials.first, surname) if initials.size > 1

      spans = []
      patterns.each do |pattern|
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          span = match.begin(0)...match.end(0)
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

    # Extra single-letter initials may sit between the first initial and the
    # surname. A longer word is not an initial, so the title itself stays.
    def extra_middle_initials_pattern(letter, surname)
      extra = "[a-z](?![[:alnum:]])\\.?"
      separator = "(?:[._]+\\s*|\\s+)"
      /(?<![[:alnum:]])#{letter}\.?(?:#{separator}#{extra})+(?:#{separator})?#{surname}(?![[:alnum:]])/i
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
          offsets[match.end(0) - 1] + 1,
          match[0],
          folded[match.end(0)] == "."
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
        replacements << [ match.begin(0), match.end(0), normalize_number(match[1]) ]
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

    def normalize_number(value)
      token = value.to_s.downcase
      return token.to_i.to_s if token.match?(/\A\d+\z/)
      return NUMBER_WORDS.fetch(token) if NUMBER_WORDS.key?(token)

      ROMAN_VALUES.fetch(token)
    end
  end
end
