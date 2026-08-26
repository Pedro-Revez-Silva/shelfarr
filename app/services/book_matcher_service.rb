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
  MIN_TITLE_SIMILARITY = 65

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
      title_score = string_similarity(normalize(query_title), normalize(book_title))

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
      if title_score < MIN_TITLE_SIMILARITY
        return title_score
      end

      # Weight: 60% title, 40% author
      (title_score * 0.6 + author_score * 0.4).round
    end

    def normalize(text)
      return "" if text.blank?

      text
        .downcase
        .gsub(/[^a-z0-9\s]/, "")  # Remove special characters
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
