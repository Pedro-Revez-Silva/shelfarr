# frozen_string_literal: true

require "test_helper"

class LibraryDestinationOccupancyTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("library-destination-occupancy")
    @folder = File.join(@root, "Mistborn", "01 - The Final Empire")
    FileUtils.mkdir_p(@folder)
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "an existing ebook folder for the same work is not a collision for an audiobook" do
    File.binwrite(File.join(@folder, "book.epub"), "ebook")
    Book.create!(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      series: "Mistborn",
      series_position: "1",
      book_type: :ebook,
      file_path: @folder
    )
    audiobook = Book.new(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      series: "Mistborn",
      series_position: "1",
      book_type: :audiobook
    )

    assert_not LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end

  test "a different title or author at the same path remains a collision" do
    File.binwrite(File.join(@folder, "book.epub"), "ebook")
    Book.create!(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :ebook,
      file_path: @folder
    )
    audiobook = Book.new(
      title: "The Final Empire",
      author: "Someone Else",
      book_type: :audiobook
    )

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end

  test "the same format at the same path remains a collision" do
    File.binwrite(File.join(@folder, "book.m4b"), "audio")
    Book.create!(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook,
      file_path: @folder
    )
    second = Book.new(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: second)
  end

  test "matching work ids allow ebook and audiobook folders to share" do
    File.binwrite(File.join(@folder, "book.epub"), "ebook")
    Book.create!(
      title: "Local Title",
      author: "Local Author",
      hardcover_id: "12345",
      book_type: :ebook,
      file_path: @folder
    )
    audiobook = Book.new(
      title: "Translated Title",
      author: "Another Author",
      hardcover_id: "12345",
      book_type: :audiobook
    )

    assert_not LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end

  test "same-format files without a book record still occupy the folder" do
    File.binwrite(File.join(@folder, "existing.m4b"), "audio")
    audiobook = Book.new(title: "The Final Empire", author: "Brandon Sanderson", book_type: :audiobook)

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end

  test "complementary files without a book record can share the folder" do
    File.binwrite(File.join(@folder, "existing.epub"), "ebook")
    audiobook = Book.new(title: "The Final Empire", author: "Brandon Sanderson", book_type: :audiobook)

    assert_not LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end
end
