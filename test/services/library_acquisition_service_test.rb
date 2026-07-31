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
      source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
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

  test "undo_import! refuses to guess when the import has no publication record" do
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
    assert File.exist?(outside), "nothing is removed without a record of what was published"
    assert_equal "imported", detection.reload.status
  end

  test "import! in move mode consumes a whole source directory" do
    set_setting("completed_download_import_mode", "move")
    release = File.join(@source_dir, "Warbreaker")
    FileUtils.mkdir_p(release)
    File.write(File.join(release, "01 - Chapter One.mp3"), "chapter one bytes")
    File.write(File.join(release, "02 - Chapter Two.mp3"), "chapter two bytes")

    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :audiobook)
    detection = DetectedImport.create!(source_path: release, status: "importing", book_type: "audiobook")

    result = LibraryAcquisitionService.import!(
      source_path: release, book: book, owner: detection, mode: "move"
    )

    assert File.exist?(File.join(result.destination_path, "01 - Chapter One.mp3"))
    assert File.exist?(File.join(result.destination_path, "02 - Chapter Two.mp3")),
      "every file in the release is imported, not just the first"
    assert_not File.exist?(release), "move consumes the source directory once the tree is published"
    assert_equal 2, result.publication["files"].size
  end

  test "import! refuses a multi-file release when the output has no path template" do
    set_setting("audiobook_path_template", "")
    release = File.join(@source_dir, "Warbreaker")
    FileUtils.mkdir_p(release)
    File.write(File.join(release, "01 - Chapter One.mp3"), "chapter one bytes")
    File.write(File.join(release, "02 - Chapter Two.mp3"), "chapter two bytes")
    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :audiobook)
    detection = DetectedImport.create!(source_path: release, status: "importing", book_type: "audiobook")

    assert_raises LibraryFileImporter::FlatOutputUnsupportedError do
      LibraryAcquisitionService.import!(
        source_path: release, book: book, owner: detection, mode: "copy"
      )
    end

    assert_empty Dir.glob(File.join(@audiobook_dest, "*")),
      "the tracks are never scattered loose into the output root"
    assert_nil book.reload.file_path, "and the book never claims the root as its path"
    assert File.exist?(File.join(release, "01 - Chapter One.mp3")), "the source is untouched"
  end

  test "import! reverses the publication when the database claim is lost" do
    set_setting("completed_download_import_mode", "move")
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")

    conflict = lambda do |*|
      raise LibraryAcquisitionService::AcquisitionConflictError, "claimed by another process"
    end

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.stub(:claim_file_path!, conflict) do
        LibraryAcquisitionService.import!(
          source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
        )
      end
    end

    assert File.exist?(source), "a lost claim returns the moved source to the watched folder"
    assert_empty Dir.glob(File.join(@ebook_dest, "**", "*.epub")),
      "no unclaimed artifact is left behind in the library"
    assert_nil book.reload.file_path
    assert_not book.acquired?
    assert_nil detection.reload.publication_record
  end

  test "import! fails instead of committing an import it could not journal" do
    set_setting("completed_download_import_mode", "move")
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")

    unwritable = lambda do |*|
      raise ActiveRecord::StatementInvalid, "journal write failed"
    end

    assert_raises ActiveRecord::StatementInvalid do
      LibraryAcquisitionService.stub(:record_publication!, unwritable) do
        LibraryAcquisitionService.import!(
          source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
        )
      end
    end

    assert File.exist?(source), "the move is reversed while the in-memory record is still available"
    assert_empty Dir.glob(File.join(@ebook_dest, "**", "*.epub")),
      "an import whose journal could not persist never keeps its library artifact"
    assert_not book.reload.acquired?
  end

  test "undo_import! keeps the journal until the state reset commits" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook", parsed_title: "Elantris"
    )
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy", source_base: @source_dir
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    failing = ->(*) { raise ActiveRecord::RecordInvalid.new(book) }
    assert_raises ActiveRecord::RecordInvalid do
      LibraryAcquisitionService.stub(:release_book_after_undo!, failing) do
        LibraryAcquisitionService.undo_import!(detection)
      end
    end

    detection.reload
    assert_equal "imported", detection.status, "the transaction rolled the state back"
    assert detection.publication_record.present?,
      "so the journal has to survive too — without it a retried undo has nothing to work from"

    # And the retry succeeds: every reversal step is idempotent, so the already
    # removed file simply reads as absent.
    LibraryAcquisitionService.undo_import!(detection)
    assert_equal "detected", detection.reload.status
    assert_nil detection.publication_record
  end

  test "undo_import! refuses to restore over a source path taken by a different file" do
    set_setting("completed_download_import_mode", "move")
    source = File.join(@source_dir, "Brandon Sanderson - Warbreaker.epub")
    File.write(source, "dummy epub bytes")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook", parsed_title: "Warbreaker"
    )
    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :ebook)
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    # Unrelated bytes take over the pathname the move freed.
    File.write(source, "somebody else's file")

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.undo_import!(detection)
    end

    assert_equal "somebody else's file", File.read(source), "the occupant is left alone"
    assert File.exist?(result.destination_path),
      "and the library keeps the only surviving copy of the imported bytes"
    assert_equal "imported", detection.reload.status
  end

  test "undo_import! will not restore through a swapped source ancestor symlink" do
    set_setting("completed_download_import_mode", "move")
    release = File.join(@source_dir, "Warbreaker")
    FileUtils.mkdir_p(release)
    File.write(File.join(release, "01 - Chapter One.mp3"), "chapter one bytes")
    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :audiobook)
    detection = DetectedImport.create!(source_path: release, status: "importing", book_type: "audiobook")
    result = LibraryAcquisitionService.import!(
      source_path: release, book: book, owner: detection, mode: "move", source_base: @source_dir
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)
    assert_not File.exist?(release), "move consumed the source tree"

    outside = Dir.mktmpdir("laq-outside-source")
    File.symlink(outside, release)

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.undo_import!(detection)
    end

    assert_empty Dir.glob(File.join(outside, "**", "*.mp3")),
      "the restore walks the watched-folder root through pinned descriptors, not the recorded parent"
    assert File.exist?(File.join(result.destination_path, "01 - Chapter One.mp3")),
      "and the library copy is kept rather than moved somewhere unreachable"
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "import! reverses an interrupted publication instead of re-importing a consumed source" do
    set_setting("completed_download_import_mode", "move")
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")

    # Stand in for a worker killed after the journal was persisted but before
    # the book claim. Interrupt is not a StandardError, so import!'s rollback
    # never runs: the source stays consumed and the bytes sit in the library,
    # exactly as a hard kill leaves them.
    interrupted = ->(*) { raise Interrupt }
    assert_raises Interrupt do
      LibraryAcquisitionService.stub(:claim_file_path!, interrupted) do
        LibraryAcquisitionService.import!(
          source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
        )
      end
    end
    assert_not File.exist?(source), "the interrupted attempt left the source consumed"
    assert detection.reload.publication_record.present?, "and its journal behind"

    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "move", source_base: @source_dir
    )

    assert File.exist?(result.destination_path), "the retry publishes from the restored source"
    assert_not File.exist?(source), "which this second move consumes in turn"
    assert detection.reload.source_identity.present?,
      "the restored source's new identity is recorded so the retry can verify it"
    assert book.reload.acquired?
  end

  test "import! reclaims a reservation stranded by a worker killed before the journal" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")

    # A worker killed while copying bytes, before the journal write. Interrupt is
    # not a StandardError, so import!'s rollback never runs and the reservation
    # it took out is left behind with nothing to recover it.
    assert_raises Interrupt do
      LibraryAcquisitionService.stub(:record_publication!, ->(*) { raise Interrupt }) do
        LibraryAcquisitionService.import!(
          source_path: source, book: book, owner: detection, mode: "copy", source_base: @source_dir
        )
      end
    end
    assert book.reload.acquisition_blocked?, "the killed worker left its reservation behind"
    assert_nil detection.reload.publication_record, "and no journal to recover from"

    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy", source_base: @source_dir
    )

    assert book.reload.acquired?,
      "the retry reclaims its own stranded reservation instead of failing for good"
    assert File.exist?(result.destination_path)
  end

  test "import! resumes an interrupted attempt that already claimed the book" do
    source = File.join(@source_dir, "Brandon Sanderson - Mistborn.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Mistborn", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")

    first = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy", source_base: @source_dir
    )
    # The worker died before recording "imported", so the journal is still set
    # and a redelivery runs the whole import again.
    published = Dir.glob(File.join(@ebook_dest, "**", "*.epub"))

    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy", source_base: @source_dir
    )

    assert_equal first.destination_path, result.destination_path
    assert_equal published, Dir.glob(File.join(@ebook_dest, "**", "*.epub")),
      "a completed import is handed back rather than publishing a numbered duplicate"
  end

  test "undo_import! leaves pre-existing files in a shared destination directory" do
    release = File.join(@source_dir, "Warbreaker")
    FileUtils.mkdir_p(release)
    File.write(File.join(release, "01 - Chapter One.mp3"), "chapter one bytes")

    book = Book.create!(title: "Warbreaker", author: "Brandon Sanderson", book_type: :audiobook)
    detection = DetectedImport.create!(source_path: release, status: "importing", book_type: "audiobook")
    result = LibraryAcquisitionService.import!(
      source_path: release, book: book, owner: detection, mode: "copy"
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    bystander = File.join(result.destination_path, "preexisting.txt")
    File.write(bystander, "not ours")

    LibraryAcquisitionService.undo_import!(detection)

    assert File.exist?(bystander), "undo never deletes files this import did not publish"
    assert_not File.exist?(File.join(result.destination_path, "01 - Chapter One.mp3")),
      "the imported file itself is removed"
    assert File.directory?(result.destination_path),
      "a destination directory that still holds other files is kept"
  end

  test "undo_import! will not delete outside the library through a swapped ancestor symlink" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub bytes")
    book = Book.create!(title: "Elantris", author: "Brandon Sanderson", book_type: :ebook)
    detection = DetectedImport.create!(source_path: source, status: "importing", book_type: "ebook")
    result = LibraryAcquisitionService.import!(
      source_path: source, book: book, owner: detection, mode: "copy"
    )
    detection.update!(status: "imported", imported_book: result.book, suggested_book: result.book)

    outside = Dir.mktmpdir("laq-outside")
    victim = File.join(outside, "Elantris", "victim.txt")
    FileUtils.mkdir_p(File.dirname(victim))
    File.write(victim, "unrelated data")

    author_dir = File.join(@ebook_dest, "Brandon Sanderson")
    FileUtils.rm_rf(author_dir)
    File.symlink(outside, author_dir)

    assert_raises LibraryAcquisitionService::AcquisitionConflictError do
      LibraryAcquisitionService.undo_import!(detection)
    end

    assert File.exist?(victim), "removal resolves through pinned no-follow descriptors, not a pathname"
    assert_equal "imported", detection.reload.status,
      "a reversal that could not reach the published file leaves the detection imported"
    assert book.reload.acquired?, "and leaves the book acquired rather than stranding the artifact"
    assert detection.publication_record.present?, "the record is kept so undo can be retried"
  ensure
    FileUtils.rm_rf(outside) if outside
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

  def set_setting(key, value, type: "string", category: "import")
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: type, category: category
    )
  end
end
