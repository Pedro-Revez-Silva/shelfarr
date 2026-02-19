# frozen_string_literal: true

class AudiobookshelfLibraryMatcherService
  Match = Data.define(:item, :score, :match_type)

  FuzzyThreshold = 85

  def self.matches_for_many(results, limit_per_result: 3)
    results = Array(results)
    return Array.new(results.size) { [] } if results.empty?

    matcher = new
    results.map do |result|
      matcher.matches_for(
        title: result.respond_to?(:title) ? result.title : nil,
        author: result.respond_to?(:author) ? result.author : nil,
        limit: limit_per_result
      )
    end
  end

  def matches_for(title:, author:, limit: 3)
    return [] if library_items.empty?
    return [] if title.blank? && author.blank?

    query_title = normalize_text(title)
    query_author = normalize_text(author)

    matches = library_items.each_with_object([]) do |item, acc|
      item_title = normalize_text(item.title)
      item_author = normalize_text(item.author)
      next if item_title.blank? && item_author.blank?

      score = match_score(
        query_title: query_title,
        query_author: query_author,
        item_title: item_title,
        item_author: item_author
      )
      next if score < FuzzyThreshold

      match_type = score == 100 ? :exact : :fuzzy
      acc << Match.new(item: item, score: score, match_type: match_type)
    end

    matches.sort_by { |match| [-match.score, match.item.title.to_s.downcase] }.take(limit)
  end

  private

  def library_items
    @library_items ||= LibraryItem.by_synced_at_desc.to_a
  end

  def match_score(query_title:, query_author:, item_title:, item_author:)
    return 100 if query_title == item_title && query_author == item_author

    title_score = trigram_similarity(query_title, item_title)
    return title_score if query_author.blank? || item_author.blank?

    author_score = trigram_similarity(query_author, item_author)
    ((title_score * 0.7) + (author_score * 0.3)).round
  end

  def normalize_text(text)
    return "" if text.blank?

    text
      .downcase
      .gsub(/[^a-z0-9\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
  end

  def trigram_similarity(left, right)
    return 0 if left.blank? || right.blank?
    return 100 if left == right

    trigrams_left = trigrams(left)
    trigrams_right = trigrams(right)

    return 0 if trigrams_left.empty? || trigrams_right.empty?

    intersection = (trigrams_left & trigrams_right).size
    union = (trigrams_left | trigrams_right).size
    ((intersection.to_f / union) * 100).round
  end

  def trigrams(text)
    return Set.new if text.blank?

    padded = "  #{text}  "
    (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
  end
end
