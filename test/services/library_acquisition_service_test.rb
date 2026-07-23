# frozen_string_literal: true

require "test_helper"

class LibraryAcquisitionServiceTest < ActiveSupport::TestCase
  setup do
    @source_dir = Dir.mktmpdir("laq-source")
    @ebook_dest = Dir.mktmpdir("laq-ebooks")
    @audiobook_dest = Dir.mktmpdir("laq-audiobooks")

    set_setting("ebook_output_path", @ebook_dest)
    set_setting("audiobook_output_path", @audiobook_dest)
    set_setting("completed_download_import_mode", "copy")
    # Keep identification offline and library scans disabled.
    Setting.where(key: "audiobookshelf_url").destroy_all
  end

  teardown do
    [ @source_dir, @ebook_dest, @audiobook_dest ].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  test "infers book type from path" do
    assert_equal "ebook", LibraryAcquisitionService.infer_book_type("/x/Book.epub")
    assert_equal "comicbook", LibraryAcquisitionService.infer_book_type("/x/Book.cbz")
    assert_equal "audiobook", LibraryAcquisitionService.infer_book_type("/x/Book.m4b")
    assert_equal "audiobook", LibraryAcquisitionService.infer_book_type(@source_dir)
  end

  test "identify suggests an existing library book from the filename" do
    book = Book.create!(title: "Mistborn", author: "Brandon Sanderson", book_type: :ebook)
    source = File.join(@source_dir, "Brandon Sanderson - Mistborn.epub")
    File.write(source, "dummy epub bytes")

    identification = MetadataService.stub(:search, []) do
      LibraryAcquisitionService.identify(source_path: source)
    end

    assert_equal "ebook", identification.book_type
    assert_equal "Mistborn", identification.parsed_title
    assert_equal "Brandon Sanderson", identification.parsed_author
    assert_equal book, identification.suggested_book
    assert identification.candidate_books.any? { |c| c["kind"] == "library" && c["book_id"] == book.id }
  end

  test "import! copies the source into the organised library and marks the book acquired" do
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    owner = DetectedImport.create!(source_path: "unused", status: "importing")
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")

    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: owner, mode: "copy"
    )

    expected_dir = File.join(@ebook_dest, "Brandon Sanderson", "Elantris")
    expected_file = File.join(expected_dir, "Brandon Sanderson - Elantris.epub")
    assert File.exist?(expected_file), "imported file should exist in the library"
    assert File.exist?(source), "copy mode preserves the source"

    book.reload
    assert book.acquired?
    assert_equal expected_dir, book.file_path
    assert_nil book.acquisition_reservation_token
    assert_equal "copy", result.mode
  end

  test "import! refuses a book that is already acquired" do
    book = Book.create!(
      title: "Warbreaker", author: "Brandon Sanderson", book_type: :ebook,
      file_path: "/ebooks/Brandon Sanderson/Warbreaker"
    )
    owner = DetectedImport.create!(source_path: "unused", status: "importing")
    source = File.join(@source_dir, "Brandon Sanderson - Warbreaker.epub")
    File.write(source, "dummy epub bytes")

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.import!(source_path: source, book: book, owner: owner)
    end
  end

  test "undo_import! discards the copied library file and re-queues the detection" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook",
      parsed_title: "Elantris", parsed_author: "Brandon Sanderson"
    )
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy"
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    LibraryAcquisitionService.undo_import!(detection)

    detection.reload
    assert_equal "detected", detection.status
    assert_nil detection.imported_book_id
    assert_nil detection.suggested_book_id
    assert File.exist?(source), "copy mode leaves the watched-folder source in place"
    assert_not File.exist?(result.destination_path), "the redundant library copy is removed"
    assert_not Book.exists?(book.id), "the throwaway book created for the import is destroyed"
  end

  test "undo_import! restores a moved source so it can be re-imported" do
    set_setting("completed_download_import_mode", "move")
    source = File.join(@source_dir, "Brandon Sanderson - Warbreaker.epub")
    File.write(source, "dummy epub bytes")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook",
      parsed_title: "Warbreaker", parsed_author: "Brandon Sanderson"
    )
    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :ebook)
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "move"
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)
    assert_not File.exist?(source), "move consumed the source"

    LibraryAcquisitionService.undo_import!(detection)

    assert File.exist?(source), "undo returns the moved file to the watched folder"
    assert_not File.exist?(result.destination_path), "the library directory is cleared"
    assert_equal "detected", detection.reload.status
  end

  test "undo_import! un-acquires but keeps a metadata-bearing matched book" do
    source = File.join(@source_dir, "Brandon Sanderson - Mistborn.epub")
    File.write(source, "dummy epub bytes")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook",
      parsed_title: "Mistborn", parsed_author: "Brandon Sanderson"
    )
    book = Book.create!(
      title: "Mistborn", author: "Brandon Sanderson", book_type: :ebook, hardcover_id: "12345"
    )
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy"
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    LibraryAcquisitionService.undo_import!(detection)

    assert Book.exists?(book.id), "a matched book with metadata is kept"
    assert_not book.reload.acquired?, "but it is un-acquired so it can be re-imported"
  end

  test "undo_import! refuses to delete a file outside the library output root" do
    outside = File.join(@source_dir, "not-in-library.epub")
    File.write(outside, "dummy")
    book = Book.create!(title: "Rogue", book_type: :ebook, file_path: outside)
    detection = DetectedImport.create!(
      source_path: File.join(@source_dir, "still-here.epub"), status: "imported",
      book_type: "ebook", imported_book: book
    )
    File.write(detection.source_path, "dummy")

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.undo_import!(detection)
    end
    assert File.exist?(outside), "a path outside the library is never removed"
    assert_equal "imported", detection.reload.status
  end

  test "search_candidates maps provider results into scored online candidates" do
    results = [
      MetadataService::SearchResult.new(
        source: "hardcover", source_id: "42", title: "The Fellowship of the Ring",
        author: "J.R.R. Tolkien", description: nil, year: 1954, cover_url: "http://x/c.jpg",
        has_audiobook: true, has_ebook: true, series_name: nil, series_position: nil
      )
    ]

    candidates = MetadataService.stub(:search, results) do
      LibraryAcquisitionService.search_candidates(
        query: "The Fellowship of the Ring Tolkien", book_type: "audiobook"
      )
    end

    assert_equal 1, candidates.size
    candidate = candidates.first
    assert_equal "online", candidate["kind"]
    assert_equal "hardcover:42", candidate["work_id"]
    assert_equal "The Fellowship of the Ring", candidate["title"]
    assert candidate["score"].positive?, "a matching query should score above zero"
  end

  test "search_candidates returns [] for a blank query without hitting the network" do
    # A blank query must return early; if it did not, the (unstubbed) provider
    # lookup would fail in the offline test environment.
    assert_empty LibraryAcquisitionService.search_candidates(query: "   ", book_type: "ebook")
  end

  private

  def set_setting(key, value)
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: "string", category: "paths"
    )
  end
end
