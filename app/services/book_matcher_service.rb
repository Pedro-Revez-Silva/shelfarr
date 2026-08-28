# frozen_string_literal: true

# Matches parsed filename data against existing books in the library
# Uses fuzzy string matching to find potential matches
class BookMatcherService
  Result = Data.define(:book, :score, :match_type) do
    def exact?
      match_type == :exact
    end

    def fuzzy?
      match_type == :fuzzy
    end

    def no_match?
      match_type == :none
    end
  end

  # Minimum score to consider a fuzzy match
  FUZZY_THRESHOLD = 70

  # Minimum title-only similarity required before author similarity can contribute to score
  # This prevents false positives when books share author + series text but have different core titles
  # Example: "Harry Potter und die Kammer des Schreckens" vs "Harry Potter und der Gefangene von Askaban"
  # should not match despite sharing author and series metadata
  MIN_TITLE_SIMILARITY = FUZZY_THRESHOLD
  SEQUENCE_MARKER_PATTERN = /\b(book|part|vol|volume)\s*(\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b/
  SEQUENCE_NUMBER_WORDS = {
    "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5,
    "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10
  }.freeze
  ROMAN_DIGIT_VALUES = { "i" => 1, "v" => 5, "x" => 10, "l" => 50, "c" => 100, "d" => 500, "m" => 1_000 }.freeze
  TITLE_ALIAS_METADATA_WORDS = %w[
    a an anniversary audiobook biography book deluxe edition ebook illustrated
    memoir novel novella part revised special the unabridged updated vol volume
  ].freeze

  class << self
    # Find best matching book for the given title/author and book type
    # Returns Result with matched book (or nil), score, and match type
    def match(title:, author:, book_type:)
      return no_match_result if title.blank?

      candidates = Book.where(book_type: book_type)

      return no_match_result if candidates.empty?

      best_match = nil
      best_score = 0

      candidates.find_each do |book|
        score = calculate_match_score(
          query_title: title,
          query_author: author,
          book_title: book.title,
          book_author: book.author
        )

        if score > best_score
          best_score = score
          best_match = book
        end
      end

      if best_score >= 95
        Result.new(book: best_match, score: best_score, match_type: :exact)
      elsif best_score >= FUZZY_THRESHOLD
        Result.new(book: best_match, score: best_score, match_type: :fuzzy)
      else
        no_match_result
      end
    end

    # Find or create a book based on parsed data
    # If match found, returns existing book; otherwise creates new one
    def find_or_create_book(title:, author:, book_type:)
      result = match(title: title, author: author, book_type: book_type)

      if result.exact? || result.fuzzy?
        result.book
      else
        Book.create!(
          title: title,
          author: author,
          book_type: book_type
        )
      end
    end

    private

    def no_match_result
      Result.new(book: nil, score: 0, match_type: :none)
    end

    def calculate_match_score(query_title:, query_author:, book_title:, book_author:)
      normalized_query_title = normalize(query_title)
      normalized_book_title = normalize(book_title)
      title_score = string_similarity(normalized_query_title, normalized_book_title)
      return 0 if conflicting_sequence_markers?(normalized_query_title, normalized_book_title)

      # If no author in query, weight title more heavily
      if query_author.blank?
        return title_score
      end

      # If book has no author, still use title score but penalize slightly
      if book_author.blank?
        return (title_score * 0.9).round
      end

      author_score = string_similarity(normalize(query_author), normalize(book_author))

      # Require minimum title similarity to prevent false positives when
      # books share author + series/edition text but have different core titles
      # (e.g., "Harry Potter und die Kammer des Schreckens" vs "Harry Potter und der Gefangene von Askaban")
      if title_score < MIN_TITLE_SIMILARITY &&
          !title_alias?(query_title, book_title)
        return title_score
      end

      # Weight: 60% title, 40% author
      (title_score * 0.6 + author_score * 0.4).round
    end

    # A colon or dash-delimited subtitle/series label can lower trigram
    # similarity even when one side is still the complete core title. Require
    # that structural boundary instead of accepting arbitrary containment,
    # which would conflate sequels such as "The Cat in the Hat" and "The Cat
    # in the Hat Comes Back".
    def title_alias?(left, right)
      normalized_left = normalize(left)
      normalized_right = normalize(right)
      shorter, longer = [ normalized_left, normalized_right ].sort_by(&:length)
      return false if shorter.length < 8

      if longer.start_with?("#{shorter} ")
        suffix = longer.delete_prefix("#{shorter} ")
        return true if title_metadata_suffix?(suffix)
      end

      raw_longer = normalized_left == longer ? left : right
      segments = raw_longer.to_s
        .split(/\s*(?::|[()\u2013\u2014]|\s-\s)\s*/)
        .filter_map { |segment| normalize(segment).presence }
      return false if segments.size < 2

      # A complete title may follow a series label, as in "Mistborn: The Final
      # Empire". Text following the complete title is safe only when it is
      # edition metadata; otherwise it may be a distinct sequel subtitle.
      return true if segments.last == shorter
      return false unless segments.first == shorter

      title_metadata_suffix?(segments.drop(1).join(" "))
    end

    def title_metadata_suffix?(suffix)
      return false if suffix.match?(/\A(?:and|or|versus|vs)\b/)
      return true if suffix.match?(
        /\b(?:anniversary|audiobook|book|classics?|collection|deluxe|edition|ebook|illustrated|part|revised|series|special|unabridged|updated|vol|volume)\b/
      )

      suffix.split.all? { |word| word.in?(TITLE_ALIAS_METADATA_WORDS) }
    end

    def conflicting_sequence_markers?(left, right)
      left_markers = left.scan(SEQUENCE_MARKER_PATTERN).to_h
      right_markers = right.scan(SEQUENCE_MARKER_PATTERN).to_h

      (left_markers.keys & right_markers.keys).any? do |marker|
        left_markers.fetch(marker) != right_markers.fetch(marker)
      end
    end

    def normalize_sequence_marker(marker)
      marker.in?(%w[vol volume]) ? "volume" : marker
    end

    def normalize_sequence_number(value)
      return value.to_i.to_s if value.match?(/\A\d+\z/)
      return SEQUENCE_NUMBER_WORDS.fetch(value).to_s if SEQUENCE_NUMBER_WORDS.key?(value)

      total = 0
      previous = 0
      value.reverse.each_char do |character|
        current = ROMAN_DIGIT_VALUES.fetch(character)
        total += current < previous ? -current : current
        previous = [ previous, current ].max
      end
      total.to_s
    end

    def normalize(text)
      return "" if text.blank?

      text
        .downcase
        .gsub("&", " and ")
        .gsub(/[^a-z0-9\s]/, "")  # Remove special characters
        .gsub(SEQUENCE_MARKER_PATTERN) do
          marker = normalize_sequence_marker(Regexp.last_match(1))
          number = normalize_sequence_number(Regexp.last_match(2))
          "#{marker} #{number}"
        end
        .gsub(/\s+/, " ")         # Collapse whitespace
        .strip
    end

    # Trigram-based similarity score (0-100)
    def string_similarity(str1, str2)
      return 100 if str1 == str2
      return 0 if str1.blank? || str2.blank?

      trigram_similarity(str1, str2)
    end

    def trigram_similarity(str1, str2)
      trigrams1 = to_trigrams(str1)
      trigrams2 = to_trigrams(str2)

      return 0 if trigrams1.empty? || trigrams2.empty?

      intersection = (trigrams1 & trigrams2).size
      union = (trigrams1 | trigrams2).size

      ((intersection.to_f / union) * 100).round
    end

    def to_trigrams(str)
      padded = "  #{str}  "
      (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
    end
  end
end
