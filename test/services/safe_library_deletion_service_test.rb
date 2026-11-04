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

  test "an unrelated non-UTF8 sibling does not block deletion" do
    sibling = File.join(@root.b, "unrelated-\xFF.txt".b)
    File.binwrite(sibling, "unrelated bytes")

    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.exist?(@path)
    assert_equal "unrelated bytes", File.binread(sibling)
  end

  test "invalid names inside the target tree report a library deletion error" do
    FileUtils.rm_f(@path)
    FileUtils.mkdir_p(@path)
    File.binwrite(File.join(@path.b, "invalid-\xFF.epub".b), "book bytes")

    error = assert_raises(SafeLibraryDeletionService::Error) do
      SafeLibraryDeletionService.new(@book).delete!
    end

    assert_match(/UTF-8/, error.message)
  end

  test "unlinks a reference-mode library symlink without touching the target" do
    source = File.join(@root, "download-source.epub")
    File.binwrite(source, "download bytes")
    FileUtils.rm_f(@path)
    File.symlink(source, @path)
    @book.update!(file_path: @path)

    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.symlink?(@path)
    assert_not File.exist?(@path)
    assert File.exist?(source)
    assert_equal "download bytes", File.binread(source)
  end

  test "unlinks a final-target reference after its staging symlink is gone" do
    download_root = Dir.mktmpdir("reference-download")
    target = File.join(download_root, "content", "book.epub")
    staging = File.join(download_root, "staged.epub")
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, "remote download bytes")
    File.symlink(target, staging)
    FileUtils.rm_f(@path)
    File.symlink(Pathname(target).realpath.to_s, @path)
    File.unlink(staging)

    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.symlink?(@path)
    assert_equal "remote download bytes", File.binread(target)
  ensure
    FileUtils.rm_rf(download_root)
  end

  test "recovers an interrupted reference symlink quarantine" do
    source = File.join(@root, "download-source.epub")
    File.binwrite(source, "download bytes")
    FileUtils.rm_f(@path)
    File.symlink(source, @path)
    @book.update!(file_path: @path)

    service = SafeLibraryDeletionService.new(@book)
    quarantine = File.join(@root, "#{service.send(:quarantine_prefix)}ref-deadbeef")
    File.rename(@path, quarantine)

    assert service.delete!
    assert_not File.exist?(@path)
    assert_not File.exist?(quarantine)
    assert File.exist?(source)
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
    LibraryPathSafety::INTERNAL_DIRECTORIES.each do |directory|
      internal_directory = File.join(@root, directory)
      FileUtils.mkdir_p(internal_directory)
      internal_path = File.join(internal_directory, "staged.m4b")
      File.binwrite(internal_path, "staged bytes")
      @book.update!(file_path: internal_path)

      assert_raises(SafeLibraryDeletionService::Error) do
        SafeLibraryDeletionService.new(@book).delete!
      end
      assert_equal "staged bytes", File.binread(internal_path)
    end
  end

  test "preserves both formats when a library directory is shared" do
    folder = File.join(@root, "Shared Book")
    FileUtils.mkdir_p(folder)
    ebook_file = File.join(folder, "book.epub")
    audio_file = File.join(folder, "book.m4b")
    File.binwrite(ebook_file, "ebook bytes")
    File.binwrite(audio_file, "audio bytes")
    @book.update!(file_path: folder)
    Book.create!(title: @book.title, author: @book.author, book_type: :audiobook, file_path: folder)

    assert_raises(SafeLibraryDeletionService::Error) { SafeLibraryDeletionService.new(@book).delete! }
    assert_equal "ebook bytes", File.binread(ebook_file)
    assert_equal "audio bytes", File.binread(audio_file)
  end

  test "preserves hidden nested companion media after its library record is removed" do
    folder = File.join(@root, "Shared Book")
    nested = File.join(folder, "Audio", "Discs", "Disc 1", "Tracks")
    FileUtils.mkdir_p(nested)
    File.binwrite(File.join(folder, "book.epub"), "ebook bytes")
    audio_file = File.join(nested, ".book.m4b")
    File.binwrite(audio_file, "retained audio bytes")
    @book.update!(file_path: folder)

    assert_raises(SafeLibraryDeletionService::Error) { SafeLibraryDeletionService.new(@book).delete! }
    assert_equal "retained audio bytes", File.binread(audio_file)
    assert File.exist?(File.join(folder, "book.epub"))
  end

  test "preserves a folder reserved by an unpublished companion upload" do
    folder = File.join(@root, "Shared Book")
    FileUtils.mkdir_p(folder)
    ebook = File.join(folder, "book.epub")
    File.binwrite(ebook, "ebook bytes")
    @book.update!(file_path: folder)
    Upload.create!(user: users(:one), original_filename: "book.m4b", file_path: @path,
      file_size: File.size(@path), book_type: :audiobook, status: :processing,
      library_path: folder, destination_path: File.join(folder, "book.m4b"))

    assert_raises(SafeLibraryDeletionService::Error) { SafeLibraryDeletionService.new(@book).delete! }
    assert_equal "ebook bytes", File.binread(ebook)
  end

  test "children_for tags a non-ASCII directory name as UTF-8" do
    name = "Jürgen Weiß.epub"
    File.binwrite(File.join(@root, name), "unicode bytes")
    binary_name = name.dup.force_encoding(Encoding::ASCII_8BIT)

    File.open(@root) do |directory|
      children = SafeLibraryDeletionService.new(@book).send(:children_for, directory)
      child = children.find { |entry| entry.bytes == name.bytes }

      assert_equal name, child
      assert_equal Encoding::UTF_8, child.encoding
      refute_equal binary_name, child
    end
  end

  test "supports the configured comic library root" do
    SettingsService.set(:comicbook_output_path, @root)
    @book.update!(book_type: :comicbook)

    assert SafeLibraryDeletionService.new(@book).delete!
    assert_not File.exist?(@path)
  end

  test "removes a library file when renameat2 returns EINVAL" do
    removed = with_rename_noreplace_einval do
      SafeLibraryDeletionService.new(@book).delete!
    end

    assert_equal true, removed
    assert_not File.exist?(@path)
    assert_empty Dir.children(@root).grep(/\A\.shelfarr-delete-/)
  end

  test "removes a library directory when renameat2 returns EINVAL" do
    folder = File.join(@root, "NFS Book")
    FileUtils.mkdir_p(folder)
    File.binwrite(File.join(folder, "book.epub"), "ebook bytes")
    @book.update!(file_path: folder)

    removed = with_rename_noreplace_einval do
      SafeLibraryDeletionService.new(@book).delete!
    end

    assert_equal true, removed
    assert_not File.exist?(folder)
    assert_empty Dir.children(@root).grep(/\A\.shelfarr-delete-/)
  end

  test "refuses to replace an existing quarantine name when renameat2 returns EINVAL" do
    folder = File.join(@root, "NFS Book")
    FileUtils.mkdir_p(folder)
    File.binwrite(File.join(folder, "book.epub"), "ebook bytes")
    @book.update!(file_path: folder)
    service = SafeLibraryDeletionService.new(@book)
    quarantine = File.join(@root, service.send(:quarantine_basename, File.stat(folder)))
    FileUtils.mkdir_p(quarantine)
    File.binwrite(File.join(quarantine, "other.epub"), "other bytes")

    service.stub(:quarantined_entries, []) do
      with_rename_noreplace_einval do
        FilesystemSyscalls.stub(:renameat, ->(*) { flunk "plain rename must not replace a present quarantine name" }) do
          assert_raises(SafeLibraryDeletionService::Error) { service.delete! }
        end
      end
    end

    assert_equal "ebook bytes", File.binread(File.join(folder, "book.epub"))
    assert_equal "other bytes", File.binread(File.join(quarantine, "other.epub"))
  end

  test "refuses to replace a different entry at the quarantine name when renameat2 returns EINVAL" do
    service = SafeLibraryDeletionService.new(@book)
    quarantine = File.join(@root, service.send(:quarantine_basename, File.stat(@path)))
    FileUtils.mkdir_p(quarantine)
    File.binwrite(File.join(quarantine, "nested.epub"), "kept bytes")

    service.stub(:quarantined_entries, []) do
      with_rename_noreplace_einval do
        FilesystemSyscalls.stub(:renameat, ->(*) { flunk "plain rename must not replace a present quarantine name" }) do
          assert_raises(SafeLibraryDeletionService::Error) { service.delete! }
        end
      end
    end

    assert_equal "original book", File.binread(@path)
    assert_equal "kept bytes", File.binread(File.join(quarantine, "nested.epub"))
  end

  test "removes a reference symlink when renameat2 returns EINVAL" do
    source = File.join(@root, "download-source.epub")
    File.binwrite(source, "download bytes")
    FileUtils.rm_f(@path)
    File.symlink(source, @path)
    @book.update!(file_path: @path)

    assert with_rename_noreplace_einval { SafeLibraryDeletionService.new(@book).delete! }
    assert_not File.symlink?(@path)
    assert_not File.exist?(@path)
    assert_equal "download bytes", File.binread(source)
    assert_empty Dir.children(@root).grep(/\A\.shelfarr-delete-/)
  end

  test "restores the library file when removal fails after an EINVAL quarantine" do
    with_rename_noreplace_einval do
      FilesystemSyscalls.stub(:unlinkat, ->(*) { raise Errno::EIO, "unlinkat" }) do
        error = assert_raises(SafeLibraryDeletionService::Error) do
          SafeLibraryDeletionService.new(@book).delete!
        end
        assert_match(/could not safely remove the library path/, error.message)
      end
    end

    assert_equal "original book", File.binread(@path)
    assert_empty Dir.children(@root).grep(/\A\.shelfarr-delete-/)
  end

  test "EINVAL deletion requires the single-writer NFS opt-in" do
    with_rename_noreplace_einval(allow_nonatomic: false) do
      FilesystemSyscalls.stub(:renameat, ->(*) { flunk "non-atomic rename was not authorized" }) do
        assert_raises(SafeLibraryDeletionService::Error) do
          SafeLibraryDeletionService.new(@book).delete!
        end
      end
    end

    assert_equal "original book", File.binread(@path)
  end

  test "restoration retains quarantine when non-atomic rename is not authorized" do
    service = SafeLibraryDeletionService.new(@book)
    quarantine = File.join(@root, service.send(:quarantine_basename, File.stat(@path)))
    File.rename(@path, quarantine)

    File.open(@root) do |parent|
      with_rename_noreplace_einval(allow_nonatomic: false) do
        FilesystemSyscalls.stub(:renameat, ->(*) { flunk "restoration must not race another writer" }) do
          service.send(:restore_quarantined_entry, parent, File.basename(quarantine), File.basename(@path), directory: false)
        end
      end
    end

    assert_equal "original book", File.binread(quarantine)
    assert_not File.exist?(@path)
  end

  private

  def with_rename_noreplace_einval(allow_nonatomic: true, &block)
    SettingsService.set(:allow_nonatomic_nfs_directory_publication, allow_nonatomic)
    FilesystemSyscalls.stub(:rename_noreplace, ->(*) { raise Errno::EINVAL, "renameat2" }, &block)
  end
end
