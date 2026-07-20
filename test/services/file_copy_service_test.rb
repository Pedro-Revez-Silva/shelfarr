# frozen_string_literal: true

require "test_helper"

class FileCopyServiceTest < ActiveSupport::TestCase
  setup do
    @tmp_dir = Dir.mktmpdir
    @src_file = File.join(@tmp_dir, "source.txt")
    @dest_dir = File.join(@tmp_dir, "dest")
    FileUtils.mkdir_p(@dest_dir)
    File.write(@src_file, "test content")
  end

  teardown do
    FileUtils.rm_rf(@tmp_dir)
  end

  test "cp copies a file normally" do
    dest_file = File.join(@dest_dir, "output.txt")
    FileCopyService.cp(@src_file, dest_file)

    assert File.exist?(dest_file)
    assert_equal "test content", File.read(dest_file)
  end

  test "cp_noreplace never overwrites an occupied destination" do
    dest_file = File.join(@dest_dir, "output.txt")
    File.write(dest_file, "existing library bytes")

    assert_raises(Errno::EEXIST) do
      FileCopyService.cp_noreplace(@src_file, dest_file)
    end

    assert_equal "existing library bytes", File.read(dest_file)
    assert_equal "test content", File.read(@src_file)
  end

  test "cp_noreplace preserves a destination replacement made during the copy" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileCopyService.stub(:publish_private_child_noreplace!, ->(_parent, _source, destination, _identity) {
      File.binwrite(dest_file, "concurrent replacement")
      raise Errno::EEXIST, destination
    }) do
      assert_raises(Errno::EEXIST) do
        FileCopyService.cp_noreplace(@src_file, dest_file)
      end
    end

    assert_equal "concurrent replacement", File.binread(dest_file)
    assert_equal "test content", File.binread(@src_file)
  end

  test "cp_noreplace never exposes or retains a partial final file" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileCopyService.stub(:copy_source_io, ->(_source, temporary) {
      temporary.write("partial bytes")
      temporary.flush
      raise IOError, "simulated interrupted copy"
    }) do
      assert_raises(IOError) { FileCopyService.cp_noreplace(@src_file, dest_file) }
    end

    assert_not File.exist?(dest_file)
    assert_empty Dir.children(@dest_dir)
  end

  test "cp_noreplace forces a non-executable private library mode" do
    dest_file = File.join(@dest_dir, "output.txt")
    File.chmod(0o777, @src_file)

    FileCopyService.cp_noreplace(@src_file, dest_file)

    assert_equal 0o640, File.stat(dest_file).mode & 0o777
    assert_equal 0o777, File.stat(@src_file).mode & 0o777
  end

  test "cp_io_noreplace publishes from the caller's pinned descriptor" do
    destination = File.join(@dest_dir, "descriptor-output.txt")

    File.open(@src_file, File::RDONLY | File::NOFOLLOW) do |source|
      FileCopyService.cp_io_noreplace(source, destination, root: @dest_dir)
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o640, File.stat(destination).mode & 0o777
  end

  test "same_io_content compares against a pinned destination and restores source position" do
    destination = File.join(@dest_dir, "descriptor-output.txt")
    File.binwrite(destination, "test content")

    File.open(@src_file, "rb") do |source|
      source.seek(3)
      assert FileCopyService.same_io_content?(source, destination, root: @dest_dir)
      assert_equal 3, source.pos

      File.binwrite(destination, "other content")
      assert_not FileCopyService.same_io_content?(source, destination, root: @dest_dir)
      assert_equal 3, source.pos
    end
  end

  test "open_pinned_regular_file retains the authorized descriptor after pathname replacement" do
    stat = File.stat(@src_file)
    pinned = FileCopyService.open_pinned_regular_file(
      @src_file,
      root: @tmp_dir,
      expected_device: stat.dev,
      expected_inode: stat.ino
    )
    displaced = File.join(@tmp_dir, "authorized-source.txt")
    outside = File.join(@tmp_dir, "outside.txt")
    File.binwrite(outside, "replacement bytes")
    File.rename(@src_file, displaced)
    File.symlink(outside, @src_file)

    assert_equal "test content", pinned.read
  ensure
    pinned&.close
  end

  test "open_pinned_regular_file rejects a replacement installed before open" do
    stat = File.stat(@src_file)
    replacement = File.join(@tmp_dir, "replacement-source.txt")
    File.binwrite(replacement, "replacement bytes")
    replacement_stat = File.stat(replacement)
    assert_not_equal [ stat.dev, stat.ino ], [ replacement_stat.dev, replacement_stat.ino ]
    File.rename(replacement, @src_file)

    assert_raises(Errno::ESTALE) do
      FileCopyService.open_pinned_regular_file(
        @src_file,
        root: @tmp_dir,
        expected_device: stat.dev,
        expected_inode: stat.ino
      )
    end
  end

  test "nonblocking private lock admission returns without changing persistent lock identity" do
    lock_path = File.join(@dest_dir, ".archive-build-slot-00")
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      FileCopyService.with_private_lock(lock_path, root: @dest_dir) do
        entered << true
        release.pop
      end
    end
    entered.pop
    identity = File.stat(lock_path)

    acquired = FileCopyService.with_private_lock(lock_path, root: @dest_dir, nonblock: true) do
      flunk "occupied admission slot must not run the operation"
    end

    assert_equal false, acquired
    assert_equal [ identity.dev, identity.ino ], [ File.stat(lock_path).dev, File.stat(lock_path).ino ]
  ensure
    release << true if release && holder&.alive?
    holder&.join
  end

  test "cp_noreplace rejects symbolic link and fifo sources without creating a final" do
    destination = File.join(@dest_dir, "output.txt")
    symlink = File.join(@tmp_dir, "source-link")
    fifo = File.join(@tmp_dir, "source-fifo")
    File.symlink(@src_file, symlink)
    File.mkfifo(fifo)

    assert_raises(FileCopyService::UnsafePathError) do
      FileCopyService.cp_noreplace(symlink, destination)
    end
    assert_raises(FileCopyService::UnsafePathError) do
      FileCopyService.cp_noreplace(fifo, destination)
    end
    assert_not File.exist?(destination)
  end

  test "cp_noreplace detects an ancestor swap and never publishes outside the pinned directory" do
    nested = File.join(@dest_dir, "nested")
    moved = File.join(@dest_dir, "pinned-original")
    outside = File.join(@tmp_dir, "outside")
    FileUtils.mkdir_p(nested)
    FileUtils.mkdir_p(outside)
    destination = File.join(nested, "output.txt")
    real_copy = FileCopyService.method(:copy_source_io)
    swapped = false

    FileCopyService.stub(:copy_source_io, ->(source, temporary) {
      real_copy.call(source, temporary)
      unless swapped
        swapped = true
        File.rename(nested, moved)
        File.symlink(outside, nested)
      end
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_not File.exist?(File.join(outside, "output.txt"))
    assert_equal "test content", File.binread(File.join(moved, "output.txt"))
    assert_equal [ "output.txt" ], Dir.children(moved)
  end

  test "snapshotted source root rejects a swapped nested symlink" do
    source_root_path = File.join(@tmp_dir, "download")
    nested = File.join(source_root_path, "disc-one")
    moved = File.join(source_root_path, "original-disc-one")
    outside = File.join(@tmp_dir, "outside-source")
    FileUtils.mkdir_p(nested)
    FileUtils.mkdir_p(outside)
    File.binwrite(File.join(nested, "chapter.mp3"), "expected chapter")
    File.binwrite(File.join(outside, "chapter.mp3"), "outside bytes")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    File.rename(nested, moved)
    File.symlink(outside, nested)
    destination = File.join(@dest_dir, "chapter.mp3")

    assert_raises(FileCopyService::UnsafePathError, Errno::ESTALE) do
      FileCopyService.cp_noreplace(
        File.join(nested, "chapter.mp3"),
        destination,
        root: @dest_dir,
        source_root: snapshot
      )
    end

    assert_not File.exist?(destination)
    assert_equal "outside bytes", File.binread(File.join(outside, "chapter.mp3"))
  end

  test "source snapshots bound both entry count and directory depth" do
    source_root_path = File.join(@tmp_dir, "bounded-download")
    nested = File.join(source_root_path, "nested")
    FileUtils.mkdir_p(nested)
    File.binwrite(File.join(source_root_path, "one.mp3"), "one")
    File.binwrite(File.join(nested, "two.mp3"), "two")

    assert_raises(FileCopyService::UnsafePathError) do
      FileCopyService.snapshot_source_root(source_root_path, max_entries: 1)
    end
    assert_raises(FileCopyService::UnsafePathError) do
      FileCopyService.snapshot_source_root(source_root_path, max_depth: 0)
    end
  end

  test "source snapshots retain UTF-8 encoding for UTF-8 entry names" do
    source_root_path = File.join(@tmp_dir, "unicode-download")
    filename = "The Reverse Centaur’s Guide.mp3"
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(File.join(source_root_path, filename), "chapter")

    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    snapshotted_name = snapshot.entries.keys.fetch(0)

    assert_equal filename, snapshotted_name
    assert_equal Encoding::UTF_8, snapshotted_name.encoding
  end

  test "source snapshots reject invalid UTF-8 names in nested directories" do
    source_root_path = File.join(@tmp_dir, "invalid-name-download")
    nested = File.join(source_root_path, "nested")
    invalid_filename = "chapter-\xFF.mp3".b
    FileUtils.mkdir_p(nested)
    File.binwrite(File.join(nested, invalid_filename), "chapter")

    error = assert_raises(FileCopyService::UnsafePathError) do
      FileCopyService.snapshot_source_root(source_root_path)
    end

    assert_match(/not valid UTF-8/, error.message)
  end

  test "snapshotted source root rejects a same-path file replacement" do
    source_root_path = File.join(@tmp_dir, "download")
    FileUtils.mkdir_p(source_root_path)
    source_file = File.join(source_root_path, "chapter.mp3")
    File.binwrite(source_file, "expected chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    original_stat = File.stat(source_file)
    replacement = File.join(source_root_path, "replacement-chapter.mp3")
    File.binwrite(replacement, "replacement bytes")
    replacement_stat = File.stat(replacement)
    assert_not_equal [ original_stat.dev, original_stat.ino ], [ replacement_stat.dev, replacement_stat.ino ]
    File.rename(replacement, source_file)
    destination = File.join(@dest_dir, "chapter.mp3")

    assert_raises(Errno::ESTALE) do
      FileCopyService.cp_noreplace(
        source_file,
        destination,
        root: @dest_dir,
        source_root: snapshot
      )
    end
    assert_not File.exist?(destination)
  end

  test "snapshotted source root rejects in-place content mutation" do
    source_root_path = File.join(@tmp_dir, "download")
    FileUtils.mkdir_p(source_root_path)
    source_file = File.join(source_root_path, "chapter.mp3")
    File.binwrite(source_file, "original chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    snapshotted_stat = File.stat(source_file)
    File.open(source_file, "r+b") { |file| file.write("mutated chapter") }
    File.utime(snapshotted_stat.atime, snapshotted_stat.mtime + 1, source_file)
    destination = File.join(@dest_dir, "chapter.mp3")

    assert_raises(Errno::ESTALE) do
      FileCopyService.cp_noreplace(
        source_file,
        destination,
        root: @dest_dir,
        source_root: snapshot
      )
    end
    assert_not File.exist?(destination)
  end

  test "remove_source_tree only deletes the exact snapshotted directory" do
    source_root_path = File.join(@tmp_dir, "download")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(File.join(source_root_path, "chapter.mp3"), "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)

    assert FileCopyService.remove_source_tree(snapshot)
    assert_not File.exist?(source_root_path)
  end

  test "remove_source_tree restores a replacement that wins before quarantine" do
    source_root_path = File.join(@tmp_dir, "download")
    displaced_original = File.join(@tmp_dir, "displaced-original")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(File.join(source_root_path, "chapter.mp3"), "original chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    real_rename = FileCopyService.method(:native_rename_noreplace)
    swapped = false

    FileCopyService.stub(:native_rename_noreplace, ->(source_fd, source_name, destination_fd, destination_name) {
      unless swapped
        swapped = true
        File.rename(source_root_path, displaced_original)
        FileUtils.mkdir_p(source_root_path)
        File.binwrite(File.join(source_root_path, "replacement.mp3"), "replacement bytes")
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    }) do
      assert_not FileCopyService.remove_source_tree(snapshot)
    end

    assert_equal "replacement bytes", File.binread(File.join(source_root_path, "replacement.mp3"))
    assert_equal "original chapter", File.binread(File.join(displaced_original, "chapter.mp3"))
    assert_empty Dir.glob(File.join(@tmp_dir, ".shelfarr-remove-*"))
  end

  test "remove_source_tree retains a snapshotted directory when its children changed" do
    source_root_path = File.join(@tmp_dir, "download")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(File.join(source_root_path, "chapter.mp3"), "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    File.binwrite(File.join(source_root_path, "late-file.mp3"), "late bytes")

    assert_not FileCopyService.remove_source_tree(snapshot)
    assert_equal "chapter", File.binread(File.join(source_root_path, "chapter.mp3"))
    assert_equal "late bytes", File.binread(File.join(source_root_path, "late-file.mp3"))
  end

  test "remove_source_tree preserves a quarantine-path replacement before final deletion" do
    source_root_path = File.join(@tmp_dir, "download")
    displaced = File.join(@tmp_dir, "verified-empty-original")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(File.join(source_root_path, "chapter.mp3"), "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    real_identity = FileCopyService.method(:pinned_child_identity)
    root_checks = 0

    FileCopyService.stub(:pinned_child_identity, lambda { |parent, basename, directory: false|
      if directory && basename.start_with?(".shelfarr-remove-") && !basename.start_with?(".shelfarr-remove-child-")
        root_checks += 1
        if root_checks == 2
          quarantine_path = File.join(@tmp_dir, basename)
          File.rename(quarantine_path, displaced)
          FileUtils.mkdir_p(quarantine_path)
          File.binwrite(File.join(quarantine_path, "replacement.mp3"), "replacement")
        end
      end
      real_identity.call(parent, basename, directory: directory)
    }) do
      assert_not FileCopyService.remove_source_tree(snapshot)
    end

    assert_equal "replacement", File.binread(File.join(source_root_path, "replacement.mp3"))
    assert File.directory?(displaced)
  end

  test "create_private_directory creates a pinned owner-only child" do
    parent = File.join(@dest_dir, "private-staging")

    created = FileCopyService.create_private_directory(
      parent,
      root: @dest_dir,
      prefix: "download-42-"
    )

    assert created.name.start_with?(File.join(parent, "download-42-"))
    assert_equal :directory, created.type
    assert_equal [ created.device, created.inode ],
      [ File.stat(created.name).dev, File.stat(created.name).ino ]
    assert_equal 0o700, File.stat(created.name).mode & 0o777
  end

  test "create_private_directory detects a swapped staging parent" do
    parent = File.join(@dest_dir, "private-staging")
    moved = File.join(@dest_dir, "pinned-private-staging")
    outside = File.join(@tmp_dir, "outside-private-staging")
    FileUtils.mkdir_p(parent)
    FileUtils.mkdir_p(outside)
    real_mkdir = FileCopyService.method(:native_mkdirat)
    swapped = false

    FileCopyService.stub(:native_mkdirat, lambda { |directory_fd, basename, mode|
      result = real_mkdir.call(directory_fd, basename, mode)
      unless swapped
        swapped = true
        File.rename(parent, moved)
        File.symlink(outside, parent)
      end
      result
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.create_private_directory(
          parent,
          root: @dest_dir,
          prefix: "download-42-"
        )
      end
    end

    assert_empty Dir.children(outside)
    assert_equal 1, Dir.children(moved).length
  end

  test "private staging file writes stay on its pinned descriptor after an ancestor swap" do
    parent = File.join(@dest_dir, "private-staging")
    moved = File.join(@dest_dir, "pinned-private-staging")
    outside = File.join(@tmp_dir, "outside-private-staging")
    FileUtils.mkdir_p(parent)
    FileUtils.mkdir_p(outside)
    created = FileCopyService.create_private_file(
      parent,
      root: @dest_dir,
      prefix: "archive-",
      suffix: ".zip"
    )

    File.rename(parent, moved)
    File.symlink(outside, parent)
    created.io.write("private bytes")
    created.io.flush
    created.io.fsync
    created.io.close

    assert_equal "private bytes", File.binread(File.join(moved, File.basename(created.name)))
    assert_equal 0o600, File.stat(File.join(moved, File.basename(created.name))).mode & 0o777
    assert_empty Dir.children(outside)
  end

  test "identity-scoped directory cleanup preserves a same-path replacement" do
    parent = File.join(@dest_dir, "private-staging")
    FileUtils.mkdir_p(parent)
    child = File.join(parent, "download-old")
    displaced = File.join(parent, "download-old-original")
    FileUtils.mkdir_p(child)
    File.binwrite(File.join(child, "partial"), "original")
    identity = File.stat(child)
    File.rename(child, displaced)
    FileUtils.mkdir_p(child)
    File.binwrite(File.join(child, "replacement"), "preserve me")

    assert_not FileCopyService.remove_directory_child_if_identity(
      parent,
      "download-old",
      root: @dest_dir,
      device: identity.dev,
      inode: identity.ino
    )

    assert_equal "preserve me", File.binread(File.join(child, "replacement"))
    assert_equal "original", File.binread(File.join(displaced, "partial"))
  end

  test "mv_directory_noreplace atomically publishes a complete regular tree" do
    source = File.join(@tmp_dir, "staging-tree")
    destination = File.join(@dest_dir, "published-tree")
    FileUtils.mkdir_p(File.join(source, "disc"))
    File.binwrite(File.join(source, "chapter.mp3"), "one")
    File.binwrite(File.join(source, "disc", "chapter.mp3"), "two")
    expected_manifest = FileCopyService.directory_content_manifest(source, root: @tmp_dir)

    FileCopyService.mv_directory_noreplace(source, destination, root: @dest_dir)

    assert_not File.exist?(source)
    assert_equal expected_manifest,
      FileCopyService.directory_content_manifest(destination, root: @dest_dir)
    assert_equal 0o750, File.stat(destination).mode & 0o777
    assert_equal 0o640, File.stat(File.join(destination, "chapter.mp3")).mode & 0o777
  end

  test "mv_directory_noreplace never merges into an existing directory" do
    source = File.join(@tmp_dir, "staging-tree")
    destination = File.join(@dest_dir, "published-tree")
    FileUtils.mkdir_p(source)
    FileUtils.mkdir_p(destination)
    File.binwrite(File.join(source, "new.mp3"), "new")
    File.binwrite(File.join(destination, "winner.mp3"), "winner")

    assert_raises(Errno::EEXIST) do
      FileCopyService.mv_directory_noreplace(source, destination, root: @dest_dir)
    end

    assert_equal [ "winner.mp3" ], Dir.children(destination)
    assert_equal "winner", File.binread(File.join(destination, "winner.mp3"))
    assert_equal "new", File.binread(File.join(source, "new.mp3"))
  end

  test "mv_directory_noreplace retains publication when destination parent is swapped" do
    source = File.join(@tmp_dir, "staging-tree")
    nested = File.join(@dest_dir, "nested")
    moved = File.join(@dest_dir, "original-parent")
    outside = File.join(@tmp_dir, "outside")
    destination = File.join(nested, "published-tree")
    FileUtils.mkdir_p(source)
    FileUtils.mkdir_p(nested)
    FileUtils.mkdir_p(outside)
    File.binwrite(File.join(source, "chapter.mp3"), "complete")
    real_rename = FileCopyService.method(:native_rename_noreplace)
    swapped = false

    FileCopyService.stub(:native_rename_noreplace, lambda { |source_fd, source_name, destination_fd, destination_name|
      result = real_rename.call(source_fd, source_name, destination_fd, destination_name)
      unless swapped
        swapped = true
        File.rename(nested, moved)
        File.symlink(outside, nested)
      end
      result
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.mv_directory_noreplace(source, destination, root: @dest_dir)
      end
    end

    assert_equal "complete", File.binread(File.join(moved, "published-tree", "chapter.mp3"))
    assert_empty Dir.children(outside)
  end

  test "mv_noreplace publishes and removes the source" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileCopyService.mv_noreplace(@src_file, dest_file)

    assert_equal "test content", File.read(dest_file)
    assert_not File.exist?(@src_file)
  end

  test "mv_noreplace never overwrites an occupied destination" do
    dest_file = File.join(@dest_dir, "output.txt")
    File.write(dest_file, "existing library bytes")

    assert_raises(Errno::EEXIST) do
      FileCopyService.mv_noreplace(@src_file, dest_file)
    end

    assert_equal "existing library bytes", File.read(dest_file)
    assert_equal "test content", File.read(@src_file)
  end

  test "mv_noreplace preserves a destination replacement before source removal" do
    dest_file = File.join(@dest_dir, "output.txt")
    real_remove = FileCopyService.method(:remove_pinned_source_after_publication!)

    FileCopyService.stub(:remove_pinned_source_after_publication!, ->(source, parent, basename, parent_path, identity) {
      File.unlink(@src_file)
      File.binwrite(@src_file, "concurrent source replacement")
      real_remove.call(source, parent, basename, parent_path, identity)
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.mv_noreplace(@src_file, dest_file)
      end
    end

    assert_equal "test content", File.binread(dest_file)
    assert_equal "concurrent source replacement", File.binread(@src_file)
  end

  test "mv_noreplace uses private copy publication before removing the source" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileCopyService.mv_noreplace(@src_file, dest_file)

    assert_equal "test content", File.read(dest_file)
    assert_not File.exist?(@src_file)
  end

  test "cp falls back to buffered copy on NFS copy_file_range EACCES" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileUtils.stub(:cp, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.cp(@src_file, dest_file)
    end

    assert File.exist?(dest_file)
    assert_equal "test content", File.read(dest_file)
  end

  test "cp re-raises EACCES when not from copy_file_range" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileUtils.stub(:cp, ->(_s, _d) { raise Errno::EACCES, "some other permission error" }) do
      assert_raises(Errno::EACCES) do
        FileCopyService.cp(@src_file, dest_file)
      end
    end
  end

  test "cp_io copies from an already-open descriptor" do
    destination = File.join(@dest_dir, "descriptor.txt")
    File.chmod(0o777, @src_file)

    File.open(@src_file, "rb") do |source|
      FileCopyService.cp_io(source, destination)
    end

    assert_equal "test content", File.read(destination)
    assert_equal 0o600, File.stat(destination).mode & 0o7777
  end

  test "cp_io preserves the NFS buffered fallback" do
    destination = File.join(@dest_dir, "descriptor-nfs.txt")

    File.open(@src_file, "rb") do |source|
      IO.stub(:copy_stream, ->(*) { raise Errno::EACCES, "copy_file_range" }) do
        FileCopyService.cp_io(source, destination)
      end
    end

    assert_equal "test content", File.read(destination)
  end

  test "cp_r copies directory contents normally" do
    src_dir = File.join(@tmp_dir, "src_dir")
    FileUtils.mkdir_p(src_dir)
    File.write(File.join(src_dir, "a.txt"), "file a")
    File.write(File.join(src_dir, "b.txt"), "file b")

    FileCopyService.cp_r(src_dir, @dest_dir)

    copied_dir = File.join(@dest_dir, "src_dir")
    assert File.exist?(File.join(copied_dir, "a.txt"))
    assert_equal "file a", File.read(File.join(copied_dir, "a.txt"))
    assert_equal "file b", File.read(File.join(copied_dir, "b.txt"))
  end

  test "cp_r falls back to buffered copy on NFS copy_file_range EACCES" do
    src_dir = File.join(@tmp_dir, "src_dir")
    FileUtils.mkdir_p(src_dir)
    File.write(File.join(src_dir, "a.txt"), "file a")

    FileUtils.stub(:cp_r, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.cp_r(src_dir, @dest_dir)
    end

    copied_dir = File.join(@dest_dir, "src_dir")
    assert File.exist?(File.join(copied_dir, "a.txt"))
    assert_equal "file a", File.read(File.join(copied_dir, "a.txt"))
  end

  test "cp into directory places file inside it" do
    FileUtils.stub(:cp, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.cp(@src_file, @dest_dir)
    end

    assert File.exist?(File.join(@dest_dir, "source.txt"))
    assert_equal "test content", File.read(File.join(@dest_dir, "source.txt"))
  end

  test "cp_r re-raises EACCES when not from copy_file_range" do
    src_dir = File.join(@tmp_dir, "src_dir")
    FileUtils.mkdir_p(src_dir)

    FileUtils.stub(:cp_r, ->(_s, _d) { raise Errno::EACCES, "some other error" }) do
      assert_raises(Errno::EACCES) do
        FileCopyService.cp_r(src_dir, @dest_dir)
      end
    end
  end

  test "cp_r fallback handles nested directories" do
    src_dir = File.join(@tmp_dir, "src_dir")
    sub_dir = File.join(src_dir, "subdir")
    FileUtils.mkdir_p(sub_dir)
    File.write(File.join(src_dir, "root.txt"), "root file")
    File.write(File.join(sub_dir, "nested.txt"), "nested file")

    FileUtils.stub(:cp_r, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.cp_r(src_dir, @dest_dir)
    end

    copied_dir = File.join(@dest_dir, "src_dir")
    assert File.exist?(File.join(copied_dir, "root.txt"))
    assert_equal "root file", File.read(File.join(copied_dir, "root.txt"))
    assert File.exist?(File.join(copied_dir, "subdir", "nested.txt"))
    assert_equal "nested file", File.read(File.join(copied_dir, "subdir", "nested.txt"))
  end

  test "mv moves a file normally" do
    dest_file = File.join(@dest_dir, "output.txt")
    FileCopyService.mv(@src_file, dest_file)

    assert File.exist?(dest_file)
    assert_equal "test content", File.read(dest_file)
    assert_not File.exist?(@src_file)
  end

  test "mv falls back to buffered copy on NFS copy_file_range EACCES" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileUtils.stub(:mv, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.mv(@src_file, dest_file)
    end

    assert File.exist?(dest_file)
    assert_equal "test content", File.read(dest_file)
    assert_not File.exist?(@src_file)
  end

  test "mv re-raises EACCES when not from copy_file_range" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileUtils.stub(:mv, ->(_s, _d) { raise Errno::EACCES, "some other permission error" }) do
      assert_raises(Errno::EACCES) do
        FileCopyService.mv(@src_file, dest_file)
      end
    end

    assert File.exist?(@src_file)
  end

  test "mv tolerates source removal failure when destination copy exists" do
    dest_file = File.join(@dest_dir, "output.txt")

    FileUtils.stub(:mv, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileUtils.stub(:rm_f, ->(_path) { raise Errno::EACCES, "permission denied" }) do
        assert_nothing_raised do
          FileCopyService.mv(@src_file, dest_file)
        end
      end
    end

    assert File.exist?(dest_file)
    assert_equal "test content", File.read(dest_file)
    assert File.exist?(@src_file), "Source should remain when removal fails after a verified copy"
  end

  test "cp_r fallback copies hidden files" do
    src_dir = File.join(@tmp_dir, "src_dir")
    FileUtils.mkdir_p(src_dir)
    File.write(File.join(src_dir, ".hidden"), "hidden content")
    File.write(File.join(src_dir, "visible.txt"), "visible content")

    FileUtils.stub(:cp_r, ->(_s, _d) { raise Errno::EACCES, "copy_file_range" }) do
      FileCopyService.cp_r(src_dir, @dest_dir)
    end

    copied_dir = File.join(@dest_dir, "src_dir")
    assert File.exist?(File.join(copied_dir, ".hidden")), "Hidden file should be copied"
    assert_equal "hidden content", File.read(File.join(copied_dir, ".hidden"))
    assert_equal "visible content", File.read(File.join(copied_dir, "visible.txt"))
  end
end
