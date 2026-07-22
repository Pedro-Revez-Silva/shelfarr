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
end
