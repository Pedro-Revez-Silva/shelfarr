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
  TrigramCodepointBase = 0x110000
  EmptyTrigrams = [].freeze
  # A matcher can scan thousands of externally sourced records. Bound retained
  # trigram entries so pathological metadata cannot turn this speed cache into
  # a per-request memory spike; uncached entries still use identical scoring.
  MaxCachedTrigrams = 1_000_000
  private_constant :TrigramCodepointBase, :EmptyTrigrams, :MaxCachedTrigrams

  def initialize(cache_library_items: true)
    @cache_library_items = cache_library_items
    @prepared_items = {}
    @cached_item_trigram_count = 0
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
    query = prepare_query(title, author)
    limit = limit.to_i
    return [] if query.title.blank? || limit <= 0

    matches = []
    each_library_item(library_ids) do |item|
      prepared = prepared_item(item)
      next unless prepared

      score = match_score(
        query_title: query.title,
        query_author: query.author,
        item_titles: prepared.titles,
        item_author: prepared.author,
        query_title_trigrams: query.title_trigrams,
        query_author_trigrams: query.author_trigrams,
        item_title_trigrams_by_title: prepared.title_trigrams_by_title,
        item_author_trigrams: prepared.author_trigrams
      )
      next if score < FuzzyThreshold

      exact_author = query.author.present? && prepared.author == query.author
      match_type = prepared.titles.include?(query.title) && exact_author ? :likely : :possible
      matches << Match.new(item: item, score: score, match_type: match_type)
      matches.sort_by! { |match| match_sort_key(match) }
      matches.pop if matches.size > limit
    end

    matches
  end

  private

  PreparedQuery = Data.define(:title, :author, :title_trigrams, :author_trigrams)
  PreparedItem = Data.define(:title, :titles, :author, :title_trigrams_by_title, :author_trigrams)
  private_constant :PreparedQuery, :PreparedItem

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
    prepared = prepared_item(match.item)
    normalized_title = prepared ? prepared.title : normalize_text(match.item.title)
    [ -match.score, match.likely? ? 0 : 1, -synced_at.to_f, normalized_title, match.item.id || 0 ]
  end

  def oversized_match_text?(text)
    text.is_a?(String) && text.length > MaxMatchTextLength
  end

  def prepare_query(title, author)
    query_title = normalize_text(title)
    query_author = normalize_text(author)
    PreparedQuery.new(
      title: query_title,
      author: query_author,
      title_trigrams: query_title.present? ? trigrams(query_title) : Set.new,
      author_trigrams: query_author.present? ? trigrams(query_author) : nil
    )
  end

  def prepared_item(item)
    return build_prepared_item(item, retain_trigrams: false) unless @cache_library_items

    key = item_prep_cache_key(item)
    return @prepared_items[key] if @prepared_items.key?(key)

    @prepared_items[key] = build_prepared_item(item)
  end

  def item_prep_cache_key(item)
    [ item.id, item.title, item.subtitle, item.author ]
  end

  def build_prepared_item(item, retain_trigrams: true)
    return nil if oversized_match_text?(item.title)

    item_title = normalize_text(item.title)
    item_subtitle = oversized_match_text?(item.subtitle) ? "" : normalize_text(item.subtitle)
    item_display_title = [ item_title, item_subtitle ].compact_blank.join(" ")
    item_author = oversized_match_text?(item.author) ? "" : normalize_text(item.author)
    return nil if item_title.blank? && item_display_title.blank? && item_author.blank?

    titles = [ item_title, item_display_title ].uniq
    title_trigrams_by_title, author_trigrams = if retain_trigrams
      cacheable_item_trigrams(titles, item_author)
    else
      item_trigrams(titles, item_author)
    end
    PreparedItem.new(
      title: item_title,
      titles: titles,
      author: item_author,
      title_trigrams_by_title: title_trigrams_by_title,
      author_trigrams: author_trigrams
    )
  end

  def cacheable_item_trigrams(titles, author)
    estimated_count = titles.sum { |title| estimated_trigram_count(title) } + estimated_trigram_count(author)
    return [ nil, nil ] if @cached_item_trigram_count + estimated_count > max_cached_trigrams

    title_trigrams, author_trigrams = item_trigrams(titles, author)
    @cached_item_trigram_count += title_trigrams.sum { |_title, values| values.size }
    @cached_item_trigram_count += author_trigrams.size if author_trigrams
    [ title_trigrams, author_trigrams ]
  end

  def item_trigrams(titles, author)
    [
      titles.to_h { |title| [ title, title.present? ? trigrams(title) : EmptyTrigrams ] },
      author.present? ? trigrams(author) : nil
    ]
  end

  def estimated_trigram_count(text)
    text.present? ? text.length + 2 : 0
  end

  def max_cached_trigrams
    MaxCachedTrigrams
  end

  def match_score(query_title:, query_author:, item_titles:, item_author:,
    query_title_trigrams: nil, query_author_trigrams: nil,
    item_title_trigrams_by_title: nil, item_author_trigrams: nil)
    return 0 if item_titles.blank?
    return 100 if item_titles.include?(query_title) && query_author == item_author

    title_score = item_titles.map { |item_title|
      trigram_similarity(
        query_title,
        item_title,
        left_trigrams: query_title_trigrams,
        right_trigrams: item_title_trigrams_by_title&.[](item_title)
      )
    }.max || 0
    return title_score if query_author.blank? || item_author.blank?

    author_score = trigram_similarity(
      query_author,
      item_author,
      left_trigrams: query_author_trigrams,
      right_trigrams: item_author_trigrams
    )
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

  def trigram_similarity(left, right, left_trigrams: nil, right_trigrams: nil)
    return 0 if left.blank? || right.blank?
    return 100 if left == right

    trigrams_left = left_trigrams || trigrams(left)
    trigrams_right = right_trigrams || trigrams(right)

    return 0 if trigrams_left.empty? || trigrams_right.empty?

    intersection = trigram_overlap_size(trigrams_left, trigrams_right)
    union = trigrams_left.size + trigrams_right.size - intersection
    ((intersection.to_f / union) * 100).round
  end

  def trigram_overlap_size(left, right)
    left_index = 0
    right_index = 0
    overlap = 0

    while left_index < left.size && right_index < right.size
      comparison = left[left_index] <=> right[right_index]
      if comparison.negative?
        left_index += 1
      elsif comparison.positive?
        right_index += 1
      else
        overlap += 1
        left_index += 1
        right_index += 1
      end
    end

    overlap
  end

  def trigrams(text)
    return EmptyTrigrams if text.blank?

    codepoints = "  #{text}  ".codepoints
    values = Array.new(codepoints.length - 2) do |index|
      ((codepoints[index] * TrigramCodepointBase) + codepoints[index + 1]) * TrigramCodepointBase +
        codepoints[index + 2]
    end
    values.sort!
    values.uniq!
    values.freeze
  end
end
