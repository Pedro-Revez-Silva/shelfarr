# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibraryMatcherServiceTest < ActiveSupport::TestCase
  setup do
    LibraryItem.destroy_all
    SettingsService.set(:library_platform, "audiobookshelf")

    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      subtitle: "There and Back Again",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )

    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-2",
      title: "Dune",
      author: "Frank Herbert",
      synced_at: Time.current
    )
  end

  test "finds related titles with a likely match label for exact normalized matches" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 3
    )

    assert_equal 1, matches.size
    assert_equal "ab-1", matches.first.item.audiobookshelf_id
    assert_equal :likely, matches.first.match_type
    assert_equal "Likely match", matches.first.confidence_label
  end

  test "returns no matches for unrelated titles" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Completely Different Book",
      author: "Unknown Author",
      limit: 3
    )

    assert_empty matches
  end

  test "supports matching against many metadata results" do
    results = [
      OpenStruct.new(title: "Dune", author: "Frank Herbert"),
      OpenStruct.new(title: "Unknown", author: nil)
    ]

    matches = AudiobookshelfLibraryMatcherService.matches_for_many(results, limit_per_result: 1)

    assert_equal 2, matches.size
    assert_equal 1, matches.first.size
    assert_empty matches.last
  end

  test "uses a softer possible match label for fuzzy matches" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "Tolkien",
      limit: 3
    )

    assert_equal 1, matches.size
    assert_equal :possible, matches.first.match_type
    assert_equal "Possible match", matches.first.confidence_label
  end

  test "uses a possible match label when an exact title lacks author confirmation" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: nil,
      limit: 3
    )

    assert_equal 1, matches.size
    assert_equal :possible, matches.first.match_type
    assert_equal "Possible match", matches.first.confidence_label
  end

  test "does not match an author without a usable title" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-punctuation-only",
      title: "---",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "---",
      author: "J.R.R. Tolkien",
      limit: 3
    )

    assert_empty matches
  end

  test "matches exact non-Latin titles" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-unicode-title",
      title: "Война и мир",
      author: "Лев Толстой",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Война и мир",
      author: "Лев Толстой",
      limit: 3
    )

    assert_equal "ab-unicode-title", matches.first.item.audiobookshelf_id
    assert matches.first.likely?
  end

  test "uses Unicode case folding" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-case-folded-title",
      title: "Straße",
      author: "Case Folded Author",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "STRASSE",
      author: "CASE FOLDED AUTHOR",
      limit: 3
    )

    assert_equal "ab-case-folded-title", matches.first.item.audiobookshelf_id
    assert matches.first.likely?
  end

  test "prefers a likely match over a possible match with the same score" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-authorless-hobbit",
      title: "The Hobbit",
      author: nil,
      synced_at: 1.minute.from_now
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 1
    )

    assert_equal "ab-1", matches.first.item.audiobookshelf_id
    assert matches.first.likely?
  end

  test "rejects non-scalar and oversized matcher input safely" do
    assert_empty AudiobookshelfLibraryMatcherService.new.matches_for(
      title: [ "The Hobbit" ],
      author: "J.R.R. Tolkien"
    )

    long_prefix = "a" * AudiobookshelfLibraryMatcherService::MaxMatchTextLength
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-oversized-title",
      title: "#{long_prefix} first edition",
      author: "Long Author",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "#{long_prefix} second edition",
      author: "Long Author"
    )

    assert_empty matches
  end

  test "sorts malformed cached titles safely" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-invalid-encoding",
      title: "Dune\xFF".dup.force_encoding(Encoding::UTF_8),
      author: "Frank Herbert",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Dune",
      author: "Frank Herbert",
      limit: 3
    )

    assert matches.any? { |match| match.item.audiobookshelf_id == "ab-invalid-encoding" }
  end

  test "ignores malformed subtitles while scanning unrelated items" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-invalid-subtitle",
      title: "Unrelated",
      subtitle: "bad\xFF".dup.force_encoding(Encoding::UTF_8),
      author: "Other Author",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Dune",
      author: "Frank Herbert",
      limit: 3
    )

    assert_equal [ "ab-2" ], matches.map { |match| match.item.audiobookshelf_id }
  end

  test "streaming matches prefer the freshest equally ranked item" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-old-hobbit",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      synced_at: 2.years.ago
    )
    fresh = LibraryItem.find_by!(audiobookshelf_id: "ab-1")

    matches = AudiobookshelfLibraryMatcherService.new(cache_library_items: false).matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 1
    )

    assert_equal fresh, matches.first.item
  end

  test "does not promote an oversized title's subtitle into a match" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-oversized-title-subtitle",
      title: "x" * (AudiobookshelfLibraryMatcherService::MaxMatchTextLength + 1),
      subtitle: "Dune",
      author: "Frank Herbert",
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Dune",
      author: "Frank Herbert",
      limit: 3
    )

    assert_equal [ "ab-2" ], matches.map { |match| match.item.audiobookshelf_id }
  end

  test "ignores oversized secondary metadata without suppressing an exact title" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-oversized-secondary-metadata",
      title: "Dune",
      subtitle: "x" * (AudiobookshelfLibraryMatcherService::MaxMatchTextLength + 1),
      author: "x" * (AudiobookshelfLibraryMatcherService::MaxMatchTextLength + 1),
      synced_at: 1.minute.from_now
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "Dune",
      author: "Frank Herbert",
      limit: 3
    )

    match = matches.find { |candidate| candidate.item.audiobookshelf_id == "ab-oversized-secondary-metadata" }
    assert match
    assert match.possible?
  end

  test "does not prefer future-dated matches" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-future-hobbit",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      synced_at: 1.year.from_now
    )

    matches = AudiobookshelfLibraryMatcherService.new(cache_library_items: false).matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 1
    )

    assert_equal "ab-1", matches.first.item.audiobookshelf_id
  end

  test "matches against item subtitles when present" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit: There and Back Again",
      author: "J.R.R. Tolkien",
      limit: 3
    )

    assert_equal 1, matches.size
    assert_equal "ab-1", matches.first.item.audiobookshelf_id
  end

  test "ignores missing library items when suggesting related titles" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-missing",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      missing: true,
      synced_at: Time.current
    )

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 5
    )

    assert_equal [ "ab-1" ], matches.map { |match| match.item.audiobookshelf_id }
  end

  test "ignores cached items from inactive library platforms" do
    SettingsService.set(:library_platform, "bookorbit")

    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 5
    )

    assert_empty matches
  end

  test "same matcher instance reuses item prep across queries" do
    20.times do |index|
      LibraryItem.create!(
        library_id: "lib-audio",
        audiobookshelf_id: "ab-filler-#{index}",
        title: "Filler Title #{index}",
        subtitle: "Filler Subtitle #{index}",
        author: "Filler Author #{index}",
        synced_at: Time.current
      )
    end

    matcher = AudiobookshelfLibraryMatcherService.new
    counts = Hash.new(0)
    instrument_matcher_prep(matcher, counts)

    first_matches = matcher.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 3
    )
    after_first = counts.dup

    second_matches = matcher.matches_for(
      title: "Dune",
      author: "Frank Herbert",
      limit: 3
    )

    scannable = LibraryItem.available_for_matching.count
    extra_normalize = counts[:normalize_text] - after_first[:normalize_text]
    extra_trigrams = counts[:trigrams] - after_first[:trigrams]

    assert_equal [ "ab-1" ], first_matches.map { |match| match.item.audiobookshelf_id }
    assert_equal [ "ab-2" ], second_matches.map { |match| match.item.audiobookshelf_id }
    assert_operator scannable, :>=, 20
    assert_operator after_first[:normalize_text], :>=, scannable
    assert_operator extra_normalize, :<=, 6
    assert_operator extra_trigrams, :<=, 4
    assert_operator extra_normalize, :<, scannable
    assert_operator extra_trigrams, :<, scannable
  end

  test "reusing one matcher is cheaper than constructing a matcher per query" do
    results = [
      OpenStruct.new(title: "The Hobbit", author: "J.R.R. Tolkien"),
      OpenStruct.new(title: "Dune", author: "Frank Herbert"),
      OpenStruct.new(title: "The Hobbit: There and Back Again", author: "J.R.R. Tolkien")
    ]

    naive_counts = Hash.new(0)
    results.each do |result|
      matcher = AudiobookshelfLibraryMatcherService.new
      instrument_matcher_prep(matcher, naive_counts)
      matcher.matches_for(title: result.title, author: result.author, limit: 1)
    end

    shared_counts = Hash.new(0)
    matcher = AudiobookshelfLibraryMatcherService.new
    instrument_matcher_prep(matcher, shared_counts)
    results.each do |result|
      matcher.matches_for(title: result.title, author: result.author, limit: 1)
    end

    assert_operator shared_counts[:normalize_text], :<, naive_counts[:normalize_text]
    assert_operator shared_counts[:trigrams], :<, naive_counts[:trigrams]
  end

  test "cached matcher refreshes prep when the same in-memory item is updated" do
    matcher = AudiobookshelfLibraryMatcherService.new

    before = matcher.matches_for(title: "Dune", author: "Frank Herbert", limit: 3)
    item = before.first.item
    assert_equal "ab-2", item.audiobookshelf_id
    assert_equal 100, before.first.score

    item.update!(title: "Hyperion", author: "Dan Simmons")

    renamed = matcher.matches_for(title: "Hyperion", author: "Dan Simmons", limit: 3)
    stale = matcher.matches_for(title: "Dune", author: "Frank Herbert", limit: 3)

    assert_equal [ item.id ], renamed.map { |match| match.item.id }
    assert_equal 100, renamed.first.score
    assert stale.none? { |match| match.item.id == item.id }
  end

  test "streaming matcher refreshes prep after a persisted item update" do
    item = LibraryItem.find_by!(audiobookshelf_id: "ab-2")
    matcher = AudiobookshelfLibraryMatcherService.new(cache_library_items: false)

    before = matcher.matches_for(title: "Dune", author: "Frank Herbert", limit: 3)
    assert_equal [ item.id ], before.map { |match| match.item.id }

    item.update!(title: "Hyperion", author: "Dan Simmons")

    renamed = matcher.matches_for(title: "Hyperion", author: "Dan Simmons", limit: 3)
    stale = matcher.matches_for(title: "Dune", author: "Frank Herbert", limit: 3)

    assert_equal [ item.id ], renamed.map { |match| match.item.id }
    assert_equal 100, renamed.first.score
    assert stale.none? { |match| match.item.id == item.id }
  end

  test "optimized scoring stays equivalent to the original algorithm" do
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-near-miss",
      title: "The Hobbit Companion",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-blank-author-dune",
      title: "Dune",
      author: nil,
      synced_at: 1.minute.from_now
    )

    matcher = AudiobookshelfLibraryMatcherService.new
    queries = [
      { title: "The Hobbit", author: "J.R.R. Tolkien" },
      { title: "The Hobbit", author: "Tolkien" },
      { title: "The Hobbit", author: nil },
      { title: "The Hobbit: There and Back Again", author: "J.R.R. Tolkien" },
      { title: "Hobbit", author: "J.R.R. Tolkien" },
      { title: "Dune", author: "Frank Herbert" },
      { title: "Dune", author: nil },
      { title: "Completely Different Book", author: "Unknown Author" },
      { title: "---", author: "J.R.R. Tolkien" },
      { title: [ "The Hobbit" ], author: "J.R.R. Tolkien" }
    ]

    queries.each do |query|
      optimized = serialize_matches(matcher.matches_for(**query, limit: 5))
      reference = serialize_matches(original_matches_for(**query, limit: 5))
      assert_equal reference, optimized, query.inspect
    end
  end

  test "precomputed trigram overlap matches original set algebra" do
    matcher = AudiobookshelfLibraryMatcherService.new
    pairs = [
      [ "the hobbit", "the hobbit" ],
      [ "the hobbit", "hobbit" ],
      [ "the hobbit", "the hobbit there and back again" ],
      [ "dune", "dune messiah" ],
      [ "dune", "" ],
      [ "", "dune" ],
      [ "straße", "strasse" ],
      [ "война и мир", "война и мир" ]
    ]

    pairs.each do |left, right|
      reference = original_trigram_similarity(left, right)
      computed = matcher.send(:trigram_similarity, left, right)
      precomputed = matcher.send(
        :trigram_similarity,
        left,
        right,
        left_trigrams: matcher.send(:trigrams, left),
        right_trigrams: matcher.send(:trigrams, right)
      )

      assert_equal reference, computed, [ left, right ].inspect
      assert_equal reference, precomputed, [ left, right ].inspect
    end
  end

  private

  def instrument_matcher_prep(matcher, counts)
    matcher.singleton_class.prepend(Module.new {
      define_method(:normalize_text) do |text|
        counts[:normalize_text] += 1
        super(text)
      end

      define_method(:trigrams) do |text|
        counts[:trigrams] += 1
        super(text)
      end
    })
  end

  def serialize_matches(matches)
    matches.map { |match| [ match.item.id, match.score, match.match_type ] }
  end

  def original_matches_for(title:, author:, limit: 3)
    query_title = original_normalize_text(title)
    query_author = original_normalize_text(author)
    limit = limit.to_i
    return [] if query_title.blank? || limit <= 0

    matches = []
    LibraryItem.available_for_matching.by_synced_at_desc.each do |item|
      next if original_oversized_match_text?(item.title)

      item_title = original_normalize_text(item.title)
      item_subtitle = original_oversized_match_text?(item.subtitle) ? "" : original_normalize_text(item.subtitle)
      item_display_title = [ item_title, item_subtitle ].compact_blank.join(" ")
      item_author = original_oversized_match_text?(item.author) ? "" : original_normalize_text(item.author)
      next if item_title.blank? && item_display_title.blank? && item_author.blank?
      item_titles = [ item_title, item_display_title ].uniq

      score = original_match_score(
        query_title: query_title,
        query_author: query_author,
        item_titles: item_titles,
        item_author: item_author
      )
      next if score < AudiobookshelfLibraryMatcherService::FuzzyThreshold

      exact_author = query_author.present? && item_author == query_author
      match_type = item_titles.include?(query_title) && exact_author ? :likely : :possible
      matches << AudiobookshelfLibraryMatcherService::Match.new(item: item, score: score, match_type: match_type)
      matches.sort_by! { |match| original_match_sort_key(match) }
      matches.pop if matches.size > limit
    end

    matches
  end

  def original_match_sort_key(match)
    synced_at = match.item.effective_synced_at || Time.at(0)
    [
      -match.score,
      match.likely? ? 0 : 1,
      -synced_at.to_f,
      original_normalize_text(match.item.title),
      match.item.id || 0
    ]
  end

  def original_match_score(query_title:, query_author:, item_titles:, item_author:)
    return 0 if item_titles.blank?
    return 100 if item_titles.include?(query_title) && query_author == item_author

    title_score = item_titles.map { |item_title| original_trigram_similarity(query_title, item_title) }.max || 0
    return title_score if query_author.blank? || item_author.blank?

    author_score = original_trigram_similarity(query_author, item_author)
    ((title_score * 0.7) + (author_score * 0.3)).round
  end

  def original_trigram_similarity(left, right)
    return 0 if left.blank? || right.blank?
    return 100 if left == right

    trigrams_left = original_trigrams(left)
    trigrams_right = original_trigrams(right)
    return 0 if trigrams_left.empty? || trigrams_right.empty?

    intersection = (trigrams_left & trigrams_right).size
    union = (trigrams_left | trigrams_right).size
    ((intersection.to_f / union) * 100).round
  end

  def original_trigrams(text)
    return Set.new if text.blank?

    padded = "  #{text}  "
    (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
  end

  def original_normalize_text(text)
    return "" unless text.is_a?(String)
    return "" if text.length > AudiobookshelfLibraryMatcherService::MaxMatchTextLength

    text
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      .unicode_normalize(:nfkd)
      .gsub(/\p{Mn}/, "")
      .downcase(:fold)
      .gsub(/[^\p{Alnum}\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
  end

  def original_oversized_match_text?(text)
    text.is_a?(String) && text.length > AudiobookshelfLibraryMatcherService::MaxMatchTextLength
  end
end
