# frozen_string_literal: true

require "test_helper"

class SafeLibraryDeletionServiceTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("safe-library-deletion")
    SettingsService.set(:ebook_output_path, @root)
    @path = File.join(@root, "book.epub")
    File.binwrite(@path, "original book")
    @book = Book.create!(
      title: "Deletion Test",
      author: "Test Author",
      book_type: :ebook,
      file_path: @path
    )
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "atomically quarantines and removes the verified entry" do
    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.exist?(@path)
    assert_empty Dir.children(@root)
  end

  test "never deletes a pathname replacement installed before quarantine" do
    service = SafeLibraryDeletionService.new(@book)
    preserved = File.join(@root, "preserved-original.epub")
    real_rename = service.method(:native_rename_noreplace)
    swapped = false
    swapping_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      unless swapped
        File.rename(@path, preserved)
        File.binwrite(@path, "concurrent replacement")
        swapped = true
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    end

    service.stub(:native_rename_noreplace, swapping_rename) do
      assert_raises(SafeLibraryDeletionService::Error) { service.delete! }
    end

    assert_equal "original book", File.binread(preserved)
    assert_equal "concurrent replacement", File.binread(@path)
  end

  test "reconciles a hard exit after quarantine rename" do
    service = SafeLibraryDeletionService.new(@book)
    stat = File.stat(@path)
    quarantine = File.join(@root, service.send(:quarantine_basename, stat))
    File.rename(@path, quarantine)

    assert service.delete!
    assert_not File.exist?(@path)
    assert_not File.exist?(quarantine)
  end

  test "retains both an interrupted quarantine and a new original-path replacement" do
    service = SafeLibraryDeletionService.new(@book)
    stat = File.stat(@path)
    quarantine = File.join(@root, service.send(:quarantine_basename, stat))
    File.rename(@path, quarantine)
    File.binwrite(@path, "new replacement")

    assert_raises(SafeLibraryDeletionService::Error) { service.delete! }
    assert_equal "original book", File.binread(quarantine)
    assert_equal "new replacement", File.binread(@path)
  end

  test "never authorizes Shelfarr internal staging paths as books" do
    internal_directory = File.join(@root, OwnedMediaImportFileService::STAGING_DIRECTORY)
    FileUtils.mkdir_p(internal_directory)
    internal_path = File.join(internal_directory, "staged.m4b")
    File.binwrite(internal_path, "staged bytes")
    @book.update!(file_path: internal_path)

    assert_raises(SafeLibraryDeletionService::Error) do
      SafeLibraryDeletionService.new(@book).delete!
    end
    assert_equal "staged bytes", File.binread(internal_path)
  end

  test "supports the configured comic library root" do
    SettingsService.set(:comicbook_output_path, @root)
    @book.update!(book_type: :comicbook)

    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.exist?(@path)
  end
end
