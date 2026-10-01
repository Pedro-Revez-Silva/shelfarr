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

  test "complementary files without a book record cannot prove the same work" do
    File.binwrite(File.join(@folder, "existing.epub"), "ebook")
    audiobook = Book.new(title: "The Final Empire", author: "Brandon Sanderson", book_type: :audiobook)

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end

  test "configured symlink roots still detect a different acquired work" do
    alias_root = File.join(Dir.mktmpdir("library-alias"), "library")
    File.symlink(@root, alias_root)
    SettingsService.set(:ebook_output_path, alias_root)
    SettingsService.set(:audiobook_output_path, alias_root)
    File.binwrite(File.join(@folder, "existing.epub"), "ebook")
    Book.create!(title: "The Final Empire", author: "Different Author", book_type: :ebook,
      file_path: File.join(alias_root, "Mistborn", "01 - The Final Empire"))
    audiobook = Book.new(title: "The Final Empire", author: "Brandon Sanderson", book_type: :audiobook)

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  ensure
    FileUtils.rm_rf(File.dirname(alias_root)) if alias_root
  end

  test "leaf-backed companions are recognized beneath literal SQL wildcard characters" do
    folder = File.join(@root, "Book_100%!")
    FileUtils.mkdir_p(folder)
    file = File.join(folder, "book.epub")
    File.binwrite(file, "ebook")
    Book.create!(title: "Book", author: "Author", book_type: :ebook, file_path: file)
    audiobook = Book.new(title: "Book", author: "Author", book_type: :audiobook)

    assert_not LibraryDestinationOccupancy.occupied?(library_path: folder, book: audiobook)
  end

  test "descendant records distinguish folder case on case-sensitive filesystems" do
    Book.create!(title: "Other Book", author: "Other Author", book_type: :ebook,
      file_path: File.join(@root, "Book", "book.epub"))
    audiobook = Book.new(title: "New Book", author: "Author", book_type: :audiobook)

    assert_not LibraryDestinationOccupancy.occupied?(library_path: File.join(@root, "BOOK"), book: audiobook)
  end

  test "same-format files remain a collision beside a tracked companion" do
    File.binwrite(File.join(@folder, "existing.epub"), "ebook")
    File.binwrite(File.join(@folder, "existing.m4b"), "audio")
    Book.create!(title: "The Final Empire", author: "Brandon Sanderson", book_type: :ebook, file_path: @folder)
    audiobook = Book.new(title: "The Final Empire", author: "Brandon Sanderson", book_type: :audiobook)

    assert LibraryDestinationOccupancy.occupied?(library_path: @folder, book: audiobook)
  end
end
