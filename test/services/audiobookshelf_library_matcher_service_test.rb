# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibraryMatcherServiceTest < ActiveSupport::TestCase
  setup do
    LibraryItem.destroy_all

    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
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

  test "finds exact and fuzzy matches" do
    matches = AudiobookshelfLibraryMatcherService.new.matches_for(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      limit: 3
    )

    assert_equal 1, matches.size
    assert_equal "ab-1", matches.first.item.audiobookshelf_id
    assert_equal :exact, matches.first.match_type
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
end
