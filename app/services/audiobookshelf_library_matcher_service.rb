# frozen_string_literal: true

class AudiobookshelfLibraryMatcherService
  Match = Data.define(:item, :score, :match_type) do
    def confidence_label
      likely? ? "Likely match" : "Possible match"
    end

    def likely?
      match_type == :likely
    end

    def possible?
      match_type == :possible
    end
  end

  FuzzyThreshold = 85
  MaxMatchTextLength = 500

  def initialize(cache_library_items: true)
    @cache_library_items = cache_library_items
  end

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

  def matches_for(title:, author:, limit: 3, library_ids: nil)
    query_title = normalize_text(title)
    query_author = normalize_text(author)
    limit = limit.to_i
    return [] if query_title.blank? || limit <= 0

    matches = []
    each_library_item(library_ids) do |item|
      next if oversized_match_text?(item.title)

      item_title = normalize_text(item.title)
      item_subtitle = oversized_match_text?(item.subtitle) ? "" : normalize_text(item.subtitle)
      item_display_title = [ item_title, item_subtitle ].compact_blank.join(" ")
      item_author = oversized_match_text?(item.author) ? "" : normalize_text(item.author)
      next if item_title.blank? && item_display_title.blank? && item_author.blank?
      item_titles = [ item_title, item_display_title ].uniq

      score = match_score(
        query_title: query_title,
        query_author: query_author,
        item_titles: item_titles,
        item_author: item_author
      )
      next if score < FuzzyThreshold

      exact_author = query_author.present? && item_author == query_author
      match_type = item_titles.include?(query_title) && exact_author ? :likely : :possible
      matches << Match.new(item: item, score: score, match_type: match_type)
      matches.sort_by! { |match| match_sort_key(match) }
      matches.pop if matches.size > limit
    end

    matches
  end

  private

  def library_ids_for_scope(library_ids)
    @library_items_by_ids ||= {}
    @library_items_by_ids[library_ids] ||= library_scope(library_ids).by_synced_at_desc.to_a
  end

  def library_items(library_ids = nil)
    return @all_library_items ||= library_scope.by_synced_at_desc.to_a if library_ids.nil?
    library_ids_for_scope(library_ids)
  end

  def each_library_item(library_ids, &block)
    if @cache_library_items
      library_items(library_ids).each(&block)
    else
      library_scope(library_ids).find_each(batch_size: 500, &block)
    end
  end

  def library_scope(library_ids = nil)
    scope = LibraryItem.available_for_matching
    library_ids.nil? ? scope : scope.for_libraries(library_ids)
  end

  def match_sort_key(match)
    synced_at = match.item.effective_synced_at || Time.at(0)
    [ -match.score, match.likely? ? 0 : 1, -synced_at.to_f, normalize_text(match.item.title), match.item.id || 0 ]
  end

  def oversized_match_text?(text)
    text.is_a?(String) && text.length > MaxMatchTextLength
  end

  def match_score(query_title:, query_author:, item_titles:, item_author:)
    return 0 if item_titles.blank?
    return 100 if item_titles.include?(query_title) && query_author == item_author

    title_score = item_titles.map { |item_title| trigram_similarity(query_title, item_title) }.max || 0
    return title_score if query_author.blank? || item_author.blank?

    author_score = trigram_similarity(query_author, item_author)
    ((title_score * 0.7) + (author_score * 0.3)).round
  end

  def normalize_text(text)
    return "" unless text.is_a?(String)
    return "" if text.length > MaxMatchTextLength

    text
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      .unicode_normalize(:nfkd)
      .gsub(/\p{Mn}/, "")
      .downcase(:fold)
      .gsub(/[^\p{Alnum}\s]/, " ")
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
