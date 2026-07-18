# frozen_string_literal: true

require "test_helper"
require "zip"

class LibraryDownloadArchiveServiceTest < ActiveSupport::TestCase
  BookIdentity = Struct.new(:id)

  setup do
    @output_root = Dir.mktmpdir("library-download-root")
    @source_path = File.join(@output_root, "Author", "Book")
    FileUtils.mkdir_p(@source_path)
    @book = BookIdentity.new(1_000_000_000 + SecureRandom.random_number(1_000_000_000))
  end

  teardown do
    FileUtils.rm_rf(@output_root)
    Dir.glob("book_#{@book.id}_*", base: LibraryDownloadArchiveService::CACHE_DIRECTORY).each do |entry|
      FileUtils.rm_f(LibraryDownloadArchiveService::CACHE_DIRECTORY.join(entry))
    end
  end

  test "source must be a strict descendant of the configured output root" do
    File.binwrite(File.join(@output_root, "unrelated.m4b"), "private library bytes")

    assert_raises(LibraryDownloadArchiveService::UnsafePathError) do
      LibraryDownloadArchiveService.call(
        book: @book,
        source_path: @output_root,
        output_root: @output_root
      )
    end
  end

  test "cache identity changes when an empty nested directory stat changes" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "chapter")
    empty_directory = File.join(@source_path, "booklet")
    FileUtils.mkdir_p(empty_directory)

    first_path = build_archive
    changed_time = Time.now + 5
    File.utime(changed_time, changed_time, empty_directory)
    second_path = build_archive

    refute_equal first_path, second_path
    Zip::File.open(second_path) do |archive|
      assert archive.find_entry("booklet/")
    end
  end

  test "cache files are private and use a versioned content identity" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "chapter")
    weak_cache = LibraryDownloadArchiveService::CACHE_DIRECTORY.join("book_#{@book.id}_Author_-_Book.zip")
    FileUtils.mkdir_p(weak_cache.dirname)
    File.binwrite(weak_cache, "not a trusted archive")

    cache_path = build_archive

    refute_equal weak_cache.realpath.to_s, cache_path
    assert_match(/book_#{@book.id}_v\d+_[0-9a-f]{64}\.zip\z/, File.basename(cache_path))
    assert_equal 0, File.stat(cache_path).mode & 0o077
    Zip::File.open(cache_path) do |archive|
      assert_equal "chapter", archive.get_input_stream("chapter.m4b").read
    end
  ensure
    FileUtils.rm_f(weak_cache) if weak_cache
  end

  test "ZIP entry names are safe portable relative names and source names are treated literally" do
    literal_directory = File.join(@source_path, "Disc [one]*?")
    FileUtils.mkdir_p(literal_directory)
    File.binwrite(File.join(literal_directory, "CON?.m4b"), "literal chapter")

    cache_path = build_archive

    Zip::File.open(cache_path) do |archive|
      file_entries = archive.entries.reject(&:directory?)
      assert_equal 1, file_entries.length
      entry_name = file_entries.first.name
      refute_match(%r{\A/|(?:\A|/)\.\.?/}, entry_name)
      refute_match(/[\\:*?"<>|\x00-\x1f\x7f]/, entry_name)
      entry_name.split("/").each do |component|
        refute_match(/[ .]\z/, component)
        refute_match(/\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i, component)
      end
      assert_equal "literal chapter", archive.get_input_stream(entry_name).read
    end
  end

  test "archive publication does not use pathname File.link" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "chapter")

    File.stub(:link, ->(*) { flunk "pathname File.link must not publish an archive" }) do
      assert File.file?(build_archive)
    end
  end

  test "an invalid exact-key cache file is identity-safely replaced" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "trusted chapter")
    service = archive_service
    cache_path = exact_cache_path(service)
    File.binwrite(cache_path, "corrupt cache bytes")
    File.chmod(0o600, cache_path)

    repaired_path = service.call

    assert_equal cache_path.realpath.to_s, repaired_path
    Zip::File.open(repaired_path) do |archive|
      assert_equal "trusted chapter", archive.get_input_stream("chapter.m4b").read
    end
  end

  test "a byte-shaped but structurally invalid exact-key ZIP is repaired" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "trusted chapter")
    service = archive_service
    cache_path = exact_cache_path(service)
    fake_eocd = "PK\x05\x06".b + ("\x00".b * 18)
    File.binwrite(cache_path, "PK\x03\x04malformed-central-directory".b + fake_eocd)
    File.chmod(0o600, cache_path)

    repaired_path = service.call

    Zip::File.open(repaired_path) do |archive|
      assert_equal "trusted chapter", archive.get_input_stream("chapter.m4b").read
    end
  end

  test "a cache hit refreshes its cleanup lease under the archive lock" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "leased chapter")
    cache_path = build_archive
    expired = 2.hours.ago.to_time
    File.utime(expired, expired, cache_path)

    assert_equal cache_path, build_archive
    assert_operator File.mtime(cache_path), :>, 1.minute.ago
  end

  test "a source change during the build is rejected and never published" do
    chapter = File.join(@source_path, "chapter.m4b")
    File.binwrite(chapter, "original chapter")
    service = LibraryDownloadArchiveService.new(
      book: @book,
      source_path: @source_path,
      output_root: @output_root
    )
    original_write = service.method(:write_archive!)

    service.stub(:write_archive!, lambda { |output, source_root|
      original_write.call(output, source_root)
      File.open(chapter, "ab") { |file| file.write(" changed") }
    }) do
      assert_raises(LibraryDownloadArchiveService::SourceChangedError) { service.call }
    end

    assert_empty Dir.glob("book_#{@book.id}_v*_*.zip", base: LibraryDownloadArchiveService::CACHE_DIRECTORY)
  end

  test "static symlinks and FIFOs are rejected before the descriptor snapshot opens them" do
    outside = File.join(@output_root, "outside.m4b")
    File.binwrite(outside, "outside bytes")
    unsafe_path = File.join(@source_path, "unsafe-entry")

    [ :symlink, :fifo ].each do |kind|
      kind == :symlink ? File.symlink(outside, unsafe_path) : File.mkfifo(unsafe_path)
      FileCopyService.stub(:snapshot_source_root, ->(*, **) { flunk "unsafe entry reached descriptor snapshot" }) do
        assert_raises(LibraryDownloadArchiveService::UnsafePathError) { build_archive }
      end
      FileUtils.rm_f(unsafe_path)
    end
  end

  test "same-size nested content changes invalidate cache even when mtime is restored" do
    chapter = File.join(@source_path, "chapter.m4b")
    File.binwrite(chapter, "first chapter")
    original_time = File.mtime(chapter)
    first_path = build_archive

    File.binwrite(chapter, "other chapter")
    File.utime(original_time, original_time, chapter)
    second_path = build_archive

    refute_equal first_path, second_path
    Zip::File.open(second_path) do |archive|
      assert_equal "other chapter", archive.get_input_stream("chapter.m4b").read
    end
  end

  test "canonical source path switches use a different cache identity for the same book" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "first source")
    first_path = build_archive
    alternate = File.join(@output_root, "Author", "Alternate Book")
    FileUtils.mkdir_p(alternate)
    File.binwrite(File.join(alternate, "chapter.m4b"), "second source")

    second_path = LibraryDownloadArchiveService.call(
      book: @book,
      source_path: alternate,
      output_root: @output_root
    )

    refute_equal first_path, second_path
    Zip::File.open(second_path) do |archive|
      assert_equal "second source", archive.get_input_stream("chapter.m4b").read
    end
  end

  test "concurrent builders coordinate on one valid cache path" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "concurrent chapter")
    results = Queue.new
    errors = Queue.new
    threads = 4.times.map do
      Thread.new do
        results << build_archive
      rescue => error
        errors << error
      end
    end
    threads.each(&:join)

    concurrent_error = errors.pop unless errors.empty?
    error_detail = [ concurrent_error, concurrent_error&.cause, *concurrent_error&.cause&.backtrace&.first(5) ].compact
    assert_nil concurrent_error, "concurrent archive error: #{error_detail.join("\n")}"
    paths = 4.times.map { results.pop }
    assert_equal 1, paths.uniq.length
    Zip::File.open(paths.first) do |archive|
      assert_equal "concurrent chapter", archive.get_input_stream("chapter.m4b").read
    end
    lock_path = LibraryDownloadArchiveService.lock_path_for_book(@book.id)
    assert File.file?(lock_path)
  end

  test "archive coordination uses a fixed persistent lock shard pool" do
    paths = 1.upto(LibraryDownloadArchiveService::ARCHIVE_LOCK_SHARDS * 2).map do |book_id|
      LibraryDownloadArchiveService.lock_path_for_book(book_id).basename.to_s
    end

    assert_equal LibraryDownloadArchiveService::ARCHIVE_LOCK_SHARDS, paths.uniq.length
    assert_equal paths.first, paths[LibraryDownloadArchiveService::ARCHIVE_LOCK_SHARDS]
  end

  test "portable ZIP-name collisions are rejected" do
    File.binwrite(File.join(@source_path, "chapter?.m4b"), "question")
    File.binwrite(File.join(@source_path, "chapter*.m4b"), "asterisk")

    assert_raises(LibraryDownloadArchiveService::UnsafePathError) { build_archive }
  end

  test "directory-only sources preserve empty directories" do
    FileUtils.mkdir_p(File.join(@source_path, "disc", "booklet"))

    Zip::File.open(build_archive) do |archive|
      assert archive.find_entry("disc/")
      assert archive.find_entry("disc/booklet/")
      assert archive.entries.all?(&:directory?)
    end
  end

  test "archive nesting depth is bounded before ZIP creation" do
    directory = @source_path
    (LibraryDownloadArchiveService::MAX_ARCHIVE_DEPTH + 1).times do
      directory = File.join(directory, "d")
      Dir.mkdir(directory)
    end

    assert_raises(LibraryDownloadArchiveService::UnsafePathError) { build_archive }
  end

  test "atomic publication falls back when hard links are unsupported" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "fallback chapter")

    FileCopyService.stub(:native_linkat, ->(*) { raise Errno::EOPNOTSUPP }) do
      Zip::File.open(build_archive) do |archive|
        assert_equal "fallback chapter", archive.get_input_stream("chapter.m4b").read
      end
    end
  end

  test "unsupported atomic publication remains inside the archive error contract" do
    File.binwrite(File.join(@source_path, "chapter.m4b"), "unsupported publication")

    error = FileCopyService.stub(:native_linkat, ->(*) { raise Errno::EOPNOTSUPP }) do
      FileCopyService.stub(:native_rename_noreplace, false) do
        assert_raises(LibraryDownloadArchiveService::Error) { build_archive }
      end
    end

    assert_equal LibraryDownloadArchiveService::Error, error.class
  end

  private

  def build_archive
    archive_service.call
  end

  def archive_service
    LibraryDownloadArchiveService.new(
      book: @book,
      source_path: @source_path,
      output_root: @output_root
    )
  end

  def exact_cache_path(service)
    _canonical_root, canonical_source = service.send(:validate_boundary!)
    source_root = FileCopyService.snapshot_source_root(
      canonical_source,
      max_entries: LibraryDownloadArchiveService::MAX_ARCHIVE_ENTRIES,
      max_depth: LibraryDownloadArchiveService::MAX_ARCHIVE_DEPTH
    )
    service.send(:prepare_cache_directory!)
    service.send(:cache_path_for, source_root)
  end
end
