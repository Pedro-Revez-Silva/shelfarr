# frozen_string_literal: true

require "test_helper"

class OwnedLibraryBookMatcherTest < ActiveSupport::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!
  end

  test "treats matching title author and narrator as an edition conflict" do
    Book.create!(
      title: "A Shared Title",
      author: "A. Writer",
      narrator: "The Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/shared"
    )
    item = @connection.owned_library_items.build(
      external_id: "B012345678",
      title: "A Shared Title",
      authors: [ "A Writer" ],
      narrators: [ "The Narrator" ]
    )

    resolution = OwnedLibraryBookMatcher.new.resolve(item)

    assert resolution.conflict?
    assert_equal :edition_collision, resolution.source
    assert_nil resolution.book
  end

  test "matches through a stable ASIN to ISBN bridge" do
    book = Book.create!(
      title: "Known Edition",
      author: "A. Writer",
      narrator: "The Narrator",
      isbn: "978-1-2345-6789-7",
      book_type: :audiobook,
      file_path: "/audiobooks/known-edition"
    )
    library_item = LibraryItem.new(
      library_platform: "audiobookshelf",
      library_id: "library-1",
      audiobookshelf_id: "item-1",
      asin: "B012345678",
      isbn: "9781234567897"
    )
    item = @connection.owned_library_items.build(
      external_id: "b012345678",
      title: "A Different Metadata Title"
    )

    resolution = OwnedLibraryBookMatcher.new(
      books: [ book ],
      library_items: [ library_item ]
    ).resolve(item)

    assert resolution.matched?
    assert_equal :isbn, resolution.source
    assert_equal book, resolution.book
  end

  test "does not use title alone when identity metadata is missing" do
    Book.create!(
      title: "A Shared Title",
      author: "A Writer",
      book_type: :audiobook,
      file_path: "/audiobooks/shared"
    )
    item = @connection.owned_library_items.build(
      external_id: "B012345678",
      title: "A Shared Title",
      authors: [ "A Writer" ],
      narrators: [ "The Narrator" ]
    )

    assert OwnedLibraryBookMatcher.new.resolve(item).conflict?
  end

  test "clearly different complete creators are not treated as a conflict" do
    Book.create!(
      title: "Home",
      author: "Local Author",
      narrator: "Local Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/home"
    )
    item = @connection.owned_library_items.build(
      external_id: "B012345678",
      title: "Home",
      authors: [ "Different Author" ],
      narrators: [ "Different Narrator" ]
    )

    resolution = OwnedLibraryBookMatcher.new.resolve(item)

    assert_not resolution.matched?
    assert_not resolution.conflict?
  end
end
