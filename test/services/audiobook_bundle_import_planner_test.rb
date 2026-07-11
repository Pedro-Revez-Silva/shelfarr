# frozen_string_literal: true

require "test_helper"

class AudiobookBundleImportPlannerTest < ActiveSupport::TestCase
  setup do
    @source = Dir.mktmpdir("bundle-planner-source")
    @destination = Dir.mktmpdir("bundle-planner-destination")
    @book = Book.new(title: "Book Two", author: "Original Author", book_type: :audiobook, series: "Example Series")
    SettingsService.set(:audiobook_path_template, "{author}/{title}")
  end

  teardown do
    FileUtils.rm_rf(@source)
    FileUtils.rm_rf(@destination)
  end

  test "plans distinct self-contained books and tracks the requested title" do
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    plan = build_plan

    assert plan
    assert_equal [ "Book One", "Book Two" ], plan.entries.map { |entry| entry.virtual_book.title }
    assert_equal File.join(@destination, "Original Author", "Book Two"), plan.tracked_entry.destination
  end

  test "does not split MP3 or FLAC chapter sets" do
    write_file("01.mp3")
    write_file("02.mp3")

    assert_nil build_plan

    FileUtils.rm_rf(@source)
    FileUtils.mkdir_p(@source)
    write_file("01.flac")
    write_file("02.flac")

    assert_nil build_plan
  end

  test "does not split mixed self-contained and chapter-based audio" do
    write_file("Book Two.m4b")
    write_file("chapter.mp3")

    assert_nil build_plan
  end

  test "does not split when another audio format is present" do
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    write_file("bonus.wav")

    assert_nil build_plan
  end

  test "does not split when file contents reveal another audio format" do
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    File.binwrite(
      File.join(@source, "bonus.mp4"),
      [ 24 ].pack("N") + "ftypM4A " + ("\0" * 12)
    )

    assert_nil build_plan
  end

  test "does not split multipart M4B releases" do
    @book.title = "One Long Book"
    write_file("One Long Book - Part 1.m4b")
    write_file("One Long Book - Part 2.m4b")

    assert_nil build_plan
  end

  test "does not split numerically ordered M4B parts with the same title" do
    @book.title = "One Long Book"
    write_file("01 - One Long Book.m4b")
    write_file("02 - One Long Book.m4b")

    assert_nil build_plan
  end

  test "does not split a bare-number continuation of the requested book" do
    @book.title = "One Long Book"
    write_file("One Long Book.m4b")
    write_file("One Long Book 2.m4b")

    assert_nil build_plan

    FileUtils.rm_rf(@source)
    FileUtils.mkdir_p(@source)
    write_file("One Long Book.m4b")
    write_file("One Long Book (2 of 2).m4b")

    assert_nil build_plan
  end

  test "does not split worded multipart continuations" do
    @book.title = "One Long Book"

    [ "Part Two", "Volume One", "Side B" ].each do |marker|
      FileUtils.rm_rf(@source)
      FileUtils.mkdir_p(@source)
      write_file("One Long Book.m4b")
      write_file("One Long Book #{marker}.m4b")

      assert_nil build_plan, "expected #{marker.inspect} to be treated as a multipart marker"
    end
  end

  test "does not split raw multipart files whose embedded titles differ" do
    @book.title = "One Long Book"
    first = write_file("One Long Book - Part 1.m4b")
    second = write_file("One Long Book - Part 2.m4b")
    results = {
      first => metadata(title: "One Long Book", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split numbered multipart files whose embedded titles differ" do
    @book.title = "One Long Book"
    first = write_file("One Long Book - 1.m4b")
    second = write_file("One Long Book - 2.m4b")
    results = {
      first => metadata(title: "One Long Book", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split dot-numbered multipart files whose embedded titles differ" do
    @book.title = "Introduction"
    first = write_file("One.Long.Book.01.m4b")
    second = write_file("One.Long.Book.02.m4b")
    results = {
      first => metadata(title: "Introduction", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split a multipart book mixed with another complete book" do
    @book.title = "Book Three"
    write_file("Book One - Part 1.m4b")
    write_file("Book One - Part 2.m4b")
    write_file("Book Three.m4b")

    assert_nil build_plan
  end

  test "does not split numerically prefixed parts whose embedded titles differ" do
    @book.title = "One Long Book"
    first = write_file("01 - One Long Book.m4b")
    second = write_file("02 - One Long Book.m4b")
    results = {
      first => metadata(title: "One Long Book", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split whitespace-numbered parts whose embedded titles differ" do
    @book.title = "One Long Book"
    first = write_file("01 One Long Book.m4b")
    second = write_file("02 One Long Book.m4b")
    results = {
      first => metadata(title: "One Long Book", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split purely numeric files mixed with another complete book" do
    @book.title = "Book Three"
    first = write_file("01.m4b")
    second = write_file("02.m4b")
    third = write_file("Book Three.m4b")
    results = {
      first => metadata(title: "One Long Book", author: "Original Author"),
      second => metadata(title: "Conclusion", author: "Original Author"),
      third => metadata(title: "Book Three", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split AAXC releases that require external companions" do
    write_file("Book One.aaxc")
    write_file("Book Two.aaxc")

    assert_nil build_plan
  end

  test "uses embedded metadata before filenames" do
    first = write_file("opaque-01.m4b")
    second = write_file("opaque-02.m4b")
    @book.title = "Requested Book"

    results = {
      first => metadata(title: "Requested Book", author: "First Author", year: 2020),
      second => metadata(title: "Other Book", author: "Second Author", year: 2021)
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      plan = build_plan

      assert plan
      assert_equal File.join(@destination, "First Author", "Requested Book"), plan.tracked_entry.destination
      assert_equal [ 2020, 2021 ], plan.entries.map { |entry| entry.virtual_book.year }
    end
  end

  test "keeps parenthetical series text when filename parsing would mistake it for an author" do
    @book.title = "Throne of Glass"
    @book.author = "Sarah J. Maas"
    write_file("Throne of Glass (Throne of Glass, Book 1).m4b")
    write_file("Crown of Midnight (Throne of Glass, Book 2).m4b")

    plan = build_plan

    assert plan
    assert_equal "Throne of Glass (Throne of Glass, Book 1)", plan.tracked_entry.virtual_book.title
    assert_equal "Sarah J. Maas", plan.tracked_entry.virtual_book.author
  end

  test "does not track an arbitrary longer title when the requested book is absent" do
    @book.title = "Dune"
    @book.author = "Frank Herbert"
    write_file("Dune Messiah.m4b")
    write_file("Children of Dune.m4b")

    assert_nil build_plan
  end

  test "does not substitute a conflicting qualified edition" do
    @book.title = "Dune (Abridged)"
    @book.author = "Frank Herbert"
    write_file("Dune (Unabridged).m4b")
    write_file("Other Book.m4b")

    assert_nil build_plan
  end

  test "does not split duplicate embedded titles" do
    first = write_file("first.m4b")
    second = write_file("second.m4b")
    same_metadata = metadata(title: "Book Two", author: "Original Author")

    MetadataExtractorService.stub(:extract, ->(path) { [ first, second ].include?(path) ? same_metadata : MetadataExtractorService::Result.empty }) do
      assert_nil build_plan
    end
  end

  test "does not split canonically equivalent embedded titles" do
    first = write_file("first.m4b")
    second = write_file("second.m4b")
    @book.title = "Café"
    results = {
      first => metadata(title: "Café", author: "Original Author"),
      second => metadata(title: "Cafe\u0301", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split embedded titles that are equivalent under full case folding" do
    first = write_file("first.m4b")
    second = write_file("second.m4b")
    @book.title = "Straße"
    results = {
      first => metadata(title: "Straße", author: "Original Author"),
      second => metadata(title: "STRASSE", author: "Original Author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not reorganize an already nested download" do
    FileUtils.mkdir_p(File.join(@source, "Book One"))
    File.write(File.join(@source, "Book One", "Book One.m4b"), "audio")
    write_file("Book Two.m4b")

    assert_nil build_plan
  end

  test "does not reorganize a download containing a hidden directory" do
    FileUtils.mkdir_p(File.join(@source, ".release-metadata"))
    File.write(File.join(@source, ".release-metadata", "manifest.json"), "{}")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    assert_nil build_plan
  end

  test "assigns matching and generic covers while preserving unrelated files" do
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    matching_cover = write_file("Book One.jpg")
    generic_cover = write_file("cover.png")
    companion_pdf = write_file("Book One.pdf")
    voucher = write_file("Book Two.voucher")
    readme = write_file("README.md")

    plan = build_plan
    one = plan.entries.find { |entry| entry.virtual_book.title == "Book One" }
    two = plan.entries.find { |entry| entry.virtual_book.title == "Book Two" }

    assert_equal [ matching_cover, generic_cover, companion_pdf ].sort, one.sidecar_paths.sort
    assert_equal [ generic_cover, voucher ].sort, two.sidecar_paths.sort
    assert_equal [ readme ], plan.unassigned_paths
  end

  test "preserves hidden files as unassigned bundle extras" do
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    hidden_extra = write_file(".bundle-metadata.json")

    plan = build_plan

    assert_includes plan.unassigned_paths, hidden_extra
  end

  test "preserves requested metadata used by the tracked path template" do
    @book.year = 1999
    @book.narrator = "Known Narrator"
    SettingsService.set(:audiobook_path_template, "{author}/{year}/{title}")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    plan = build_plan
    one = plan.entries.find { |entry| entry.virtual_book.title == "Book One" }

    assert_equal File.join(@destination, "Original Author", "1999", "Book Two"), plan.tracked_entry.destination
    assert_nil one.virtual_book.year
    assert_equal "Known Narrator", plan.tracked_entry.virtual_book.narrator
  end

  test "uses per-title folders when the configured path template is blank" do
    SettingsService.set(:audiobook_path_template, "")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    plan = build_plan

    assert_equal File.join(@destination, "Book One"), plan.entries.first.destination
    assert_equal File.join(@destination, "Book Two"), plan.entries.second.destination
  end

  test "rejects split destinations inside the source directory" do
    SettingsService.set(:audiobook_path_template, "")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    error = assert_raises(AudiobookBundleImportPlanner::UnsafeDestinationError) do
      build_plan(base_path: @source)
    end

    assert_match(/destination overlaps/i, error.message)
  end

  test "rejects split destinations that resolve into the source through a symlink" do
    SettingsService.set(:audiobook_path_template, "")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    output_alias = File.join(@destination, "output-alias")
    File.symlink(@source, output_alias)

    assert_raises(AudiobookBundleImportPlanner::UnsafeDestinationError) do
      build_plan(base_path: output_alias)
    end
  end

  test "does not split destinations that resolve to the same directory" do
    SettingsService.set(:audiobook_path_template, "")
    write_file("Book One.m4b")
    write_file("Book Two.m4b")
    shared_destination = File.join(@destination, "shared")
    FileUtils.mkdir_p(shared_destination)
    File.symlink(shared_destination, File.join(@destination, "Book One"))
    File.symlink(shared_destination, File.join(@destination, "Book Two"))

    assert_nil build_plan
  end

  test "does not split missing destinations that differ only by case" do
    SettingsService.set(:audiobook_path_template, "{author}")
    first = write_file("Book One.m4b")
    second = write_file("Book Two.m4b")
    results = {
      first => metadata(title: "Book One", author: "Case Author"),
      second => metadata(title: "Book Two", author: "case author")
    }

    MetadataExtractorService.stub(:extract, ->(path) { results.fetch(path) }) do
      assert_nil build_plan
    end
  end

  test "does not split when no entry matches the requested book" do
    @book.title = "Unrelated Request"
    write_file("Book One.m4b")
    write_file("Book Two.m4b")

    assert_nil build_plan
  end

  private

  def build_plan(base_path: @destination)
    AudiobookBundleImportPlanner.call(source: @source, book: @book, base_path: base_path)
  end

  def write_file(name)
    File.join(@source, name).tap { |path| File.binwrite(path, "audio") }
  end

  def metadata(title:, author:, year: nil)
    MetadataExtractorService::Result.new(
      title: title,
      author: author,
      year: year,
      description: nil,
      narrator: nil,
      success: true
    )
  end
end
