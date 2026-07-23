# frozen_string_literal: true

require "test_helper"
require "fiddle"

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

  test "cp_noreplace accepts safe effective mode when chmod is ignored" do
    destination = File.join(@dest_dir, "safe-mode.txt")

    FileCopyService.stub(:native_fchmod, ->(*) { }) do
      FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o600, File.stat(destination).mode & 0o777
  end

  test "cp_noreplace accepts safe effective modes when fchmod is unsupported" do
    destination = File.join(@dest_dir, "unsupported-fchmod.txt")

    FileCopyService.stub(:native_fchmod, ->(*) { raise Errno::EOPNOTSUPP }) do
      FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o600, File.stat(destination).mode & 0o777
    assert_empty Dir.children(@dest_dir) - [ "unsupported-fchmod.txt" ]
  end

  test "hardlink fallback copy accepts owner-only mode when fchmod is unsupported" do
    destination = File.join(@dest_dir, "hardlink-fallback-mode.txt")

    FileCopyService.stub(:native_fchmod, ->(*) { raise Errno::EOPNOTSUPP }) do
      FileCopyService.cp_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        hardlink_mode: true
      )
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o600, File.stat(destination).mode & 0o777
    assert FileCopyService.secure_library_file_mode?(destination, root: @dest_dir)
  end

  test "ensure_directory accepts a safe effective mode when fchmod is unsupported" do
    directory = File.join(@dest_dir, "safe-directory")

    FileCopyService.stub(:native_fchmod, ->(*) { raise Errno::EOPNOTSUPP }) do
      FileCopyService.ensure_directory(directory, root: @dest_dir)
    end

    assert File.directory?(directory)
    assert_includes FileCopyService::SAFE_LIBRARY_DIRECTORY_MODES,
      File.stat(directory).mode & 0o777
  end

  test "ensure_directory does not chmod the caller-provided root" do
    File.chmod(0o1777, @dest_dir)

    FileCopyService.stub(:native_fchmod, ->(*) { raise Errno::EPERM }) do
      FileCopyService.ensure_directory(@dest_dir, root: @dest_dir)
    end

    assert_equal 0o1777, File.stat(@dest_dir).mode & 0o7777
  end

  test "cp_noreplace rejects unsafe effective mode when chmod is ignored" do
    destination = File.join(@dest_dir, "unsafe-mode.txt")
    real_fchmod = FileCopyService.method(:native_fchmod)
    unsafe_fchmod = lambda do |descriptor, mode|
      handle = File.for_fd(descriptor, "rb", autoclose: false)
      if handle.stat.file? && mode == FileCopyService::LIBRARY_FILE_MODE
        handle.chmod(0o644)
      else
        real_fchmod.call(descriptor, mode)
      end
    end

    FileCopyService.stub(:native_fchmod, unsafe_fchmod) do
      assert_raises(FileCopyService::UnsafeFilePermissionsError) do
        FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_not File.exist?(destination)
    assert_equal "test content", File.binread(@src_file)
  end

  test "cp_noreplace rejects a source modified while its private copy is written" do
    destination = File.join(@dest_dir, "changed-source.txt")
    real_copy = FileCopyService.method(:copy_source_io)
    mutating_copy = lambda do |source, target, heartbeat: nil|
      real_copy.call(source, target, heartbeat: heartbeat)
      File.binwrite(@src_file, "other bytes!")
    end

    FileCopyService.stub(:copy_source_io, mutating_copy) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_not File.exist?(destination)
    assert_equal "other bytes!", File.binread(@src_file)
  end

  test "cp_noreplace uses exclusive copy when atomic publication is unsupported" do
    destination = File.join(@dest_dir, "compatible.txt")

    without_atomic_file_publication do
      FileCopyService.cp_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        allow_compatibility_fallback: true
      )
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o640, File.stat(destination).mode & 0o777
    assert_empty Dir.children(@dest_dir) - [ "compatible.txt" ]
  end

  test "cp_noreplace remains strict unless compatibility publication is enabled" do
    destination = File.join(@dest_dir, "strict.txt")

    without_atomic_file_publication do
      assert_raises(FileCopyService::AtomicPublicationUnsupportedError) do
        FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_not File.exist?(destination)
    assert_equal "test content", File.binread(@src_file)
    assert_empty Dir.children(@dest_dir)
  end

  test "compatibility publication never overwrites an occupied destination" do
    destination = File.join(@dest_dir, "occupied.txt")
    raced = false

    unsupported_link = lambda do |*|
      unless raced
        raced = true
        File.binwrite(destination, "concurrent library bytes")
      end
      raise Errno::EOPNOTSUPP
    end

    FileCopyService.stub(:native_linkat, unsupported_link) do
      FileCopyService.stub(:native_rename_noreplace, false) do
        assert_raises(Errno::EEXIST) do
          FileCopyService.cp_noreplace(
            @src_file,
            destination,
            root: @dest_dir,
            allow_compatibility_fallback: true
          )
        end
      end
    end

    assert_equal "concurrent library bytes", File.binread(destination)
    assert_equal "test content", File.binread(@src_file)
    assert_equal [ "occupied.txt" ], Dir.children(@dest_dir)
  end

  test "compatibility publication removes an interrupted partial destination" do
    destination = File.join(@dest_dir, "partial.txt")
    real_copy = FileCopyService.method(:copy_source_io)
    copy_calls = 0
    interrupted_copy = lambda do |source, target, heartbeat: nil|
      copy_calls += 1
      if copy_calls == 2
        target.write("partial")
        target.flush
        raise IOError, "interrupted compatibility copy"
      end

      real_copy.call(source, target, heartbeat: heartbeat)
    end

    FileCopyService.stub(:copy_source_io, interrupted_copy) do
      without_atomic_file_publication do
        assert_raises(IOError) do
          FileCopyService.cp_noreplace(
            @src_file,
            destination,
            root: @dest_dir,
            allow_compatibility_fallback: true
          )
        end
      end
    end

    assert_equal 2, copy_calls
    assert_not File.exist?(destination)
    assert_equal "test content", File.binread(@src_file)
    assert_empty Dir.children(@dest_dir)
  end

  test "mv_noreplace removes its source after compatibility publication" do
    destination = File.join(@dest_dir, "moved-compatible.txt")

    without_atomic_file_publication do
      FileCopyService.mv_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        allow_compatibility_fallback: true
      )
    end

    assert_not File.exist?(@src_file)
    assert_equal "test content", File.binread(destination)
    assert_empty Dir.children(@dest_dir) - [ "moved-compatible.txt" ]
  end

  test "mv_noreplace retains its source when file fsync is unsupported" do
    destination = File.join(@dest_dir, "unsynced-file.txt")

    FileCopyService.stub(:flush_and_sync, false) do
      assert_raises(FileCopyService::DurabilityUnsupportedError) do
        FileCopyService.mv_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert File.exist?(@src_file)
    assert_not File.exist?(destination)
  end

  test "mv_noreplace retains its source when parent fsync is unsupported" do
    destination = File.join(@dest_dir, "unsynced-parent.txt")

    FileCopyService.stub(:sync_io, false) do
      assert_raises(FileCopyService::DurabilityUnsupportedError) do
        FileCopyService.mv_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_equal "test content", File.binread(@src_file)
    assert_equal "test content", File.binread(destination)
  end

  test "mv_noreplace honors a supplied source root snapshot" do
    source_root_path = File.join(@tmp_dir, "authorized-source")
    FileUtils.mkdir_p(source_root_path)
    source = File.join(source_root_path, "book.epub")
    File.binwrite(source, "authorized bytes")
    source_root = FileCopyService.snapshot_source_root(source_root_path)
    displaced = File.join(@tmp_dir, "displaced-source")
    File.rename(source_root_path, displaced)
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "replacement bytes")
    destination = File.join(@dest_dir, "book.epub")

    assert_raises(Errno::ESTALE) do
      FileCopyService.mv_noreplace(
        source,
        destination,
        root: @dest_dir,
        source_root: source_root
      )
    end

    assert_equal "replacement bytes", File.binread(source)
    assert_not File.exist?(destination)
  end

  test "hardlink_noreplace publishes the source inode without removing or chmodding it" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    File.chmod(0o754, @src_file)

    FileCopyService.hardlink_noreplace(
      @src_file,
      destination,
      root: @dest_dir,
      source_root: nil
    )

    source_stat = File.stat(@src_file)
    destination_stat = File.stat(destination)
    assert_equal [ source_stat.dev, source_stat.ino ], [ destination_stat.dev, destination_stat.ino ]
    assert_equal 2, source_stat.nlink
    assert_equal 0o754, source_stat.mode & 0o7777
    assert_equal 0o754, destination_stat.mode & 0o7777
    assert_equal "test content", File.binread(@src_file)
    assert_empty Dir.children(@dest_dir) - [ "hardlinked.txt" ]
  end

  test "hardlink_noreplace never overwrites an occupied destination" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    File.binwrite(destination, "existing library bytes")

    error = assert_raises(Errno::EEXIST) do
      FileCopyService.hardlink_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        source_root: nil
      )
    end

    assert_instance_of Errno::EEXIST, error
    assert_equal "existing library bytes", File.binread(destination)
    assert_equal "test content", File.binread(@src_file)
    assert_equal 1, File.stat(@src_file).nlink
    assert_equal [ "hardlinked.txt" ], Dir.children(@dest_dir)
  end

  test "hardlink_noreplace classifies only initial unsupported link errors" do
    unsupported_errors = [
      Errno::EXDEV,
      Errno::EPERM,
      Errno::EOPNOTSUPP,
      Errno::ENOTSUP,
      Errno::ENOSYS,
      Errno::EMLINK,
      Fiddle::DLError,
      NotImplementedError
    ]

    unsupported_errors.each_with_index do |error_class, index|
      destination = File.join(@dest_dir, "unsupported-#{index}.txt")
      error = FileCopyService.stub(:native_linkat, ->(*) { raise error_class }) do
        assert_raises(FileCopyService::HardlinkUnsupportedError) do
          FileCopyService.hardlink_noreplace(
            @src_file,
            destination,
            root: @dest_dir,
            source_root: nil
          )
        end
      end

      assert_instance_of error_class, error.cause
      assert_not File.exist?(destination)
      FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)
      assert_empty Dir.children(@dest_dir)
    end
  end

  test "hardlink_noreplace does not classify a post-publication error as unsupported" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    real_validate = FileCopyService.method(:validate_published_child!)

    error = FileCopyService.stub(:validate_published_child!, lambda { |*args, **kwargs|
      real_validate.call(*args, **kwargs)
      raise Errno::EXDEV
    }) do
      assert_raises(Errno::EXDEV) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_instance_of Errno::EXDEV, error
    assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
      [ File.stat(destination).dev, File.stat(destination).ino ]
    assert_equal [ "hardlinked.txt" ], Dir.children(@dest_dir)
  end

  test "hardlink_noreplace cleans its verified temp and lock after publication failure" do
    destination = File.join(@dest_dir, "hardlinked.txt")

    FileCopyService.stub(:publish_private_child_noreplace!, ->(*) { raise IOError, "publication failed" }) do
      assert_raises(IOError) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_not File.exist?(destination)
    assert_equal 1, File.stat(@src_file).nlink
    assert_empty Dir.children(@dest_dir)
  end

  test "hardlink_noreplace cleanup preserves a replacement at its temp path" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    displaced = File.join(@dest_dir, "displaced-private-link")
    replacement = nil

    publish = lambda do |_parent, temporary_basename, _destination_basename, _identity, mode:|
      temporary = File.join(@dest_dir, temporary_basename)
      File.rename(temporary, displaced)
      File.binwrite(temporary, "replacement temp")
      replacement = temporary
      raise IOError, "publication failed"
    end

    FileCopyService.stub(:publish_private_child_noreplace!, publish) do
      assert_raises(IOError) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_equal "replacement temp", File.binread(replacement)
    assert_equal "test content", File.binread(displaced)
    assert_equal 2, File.stat(@src_file).nlink
    assert_equal 1, Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).size
  end

  test "hardlink_noreplace cleanup restores a temp replacement swapped after initial verification" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    displaced = File.join(@dest_dir, "displaced-verified-link")
    replacement = nil
    real_rename = FileCopyService.method(:native_renameat)
    swapped = false

    racing_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      if !swapped && source_name.match?(/\A\.shelfarr-copy-.*\.tmp\z/) &&
          destination_name == FileCopyService::COPY_QUARANTINE_ENTRY
        swapped = true
        temporary = File.join(@dest_dir, source_name)
        File.rename(temporary, displaced)
        File.binwrite(temporary, "replacement after verification")
        replacement = temporary
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_renameat, racing_rename) do
      FileCopyService.hardlink_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        source_root: nil
      )
    end

    assert swapped
    assert_equal "replacement after verification", File.binread(replacement)
    assert_equal "test content", File.binread(displaced)
    assert_equal 3, File.stat(@src_file).nlink
    assert_empty Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*"))
    assert_equal 1, Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).size
  end

  test "hardlink_noreplace cleanup does not require no-replace rename support" do
    destination = File.join(@dest_dir, "hardlinked.txt")

    FileCopyService.stub(:native_rename_noreplace, false) do
      FileCopyService.hardlink_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        source_root: nil
      )
    end

    assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
      [ File.stat(destination).dev, File.stat(destination).ino ]
    assert_equal [ "hardlinked.txt" ], Dir.children(@dest_dir)
  end

  test "destination-local EMLINK falls back to no-replace rename publication" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    real_link = FileCopyService.method(:native_linkat)
    link_calls = 0

    linking = lambda do |source_fd, source_name, destination_fd, destination_name|
      link_calls += 1
      raise Errno::EMLINK if link_calls == 2

      real_link.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_linkat, linking) do
      FileCopyService.hardlink_noreplace(
        @src_file,
        destination,
        root: @dest_dir,
        source_root: nil
      )
    end

    assert_equal 2, link_calls
    assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
      [ File.stat(destination).dev, File.stat(destination).ino ]
    assert_equal [ "hardlinked.txt" ], Dir.children(@dest_dir)
  end

  test "destination-local low-level link failures fall back to rename publication" do
    [ Fiddle::DLError, NotImplementedError ].each_with_index do |error_class, index|
      destination = File.join(@dest_dir, "hardlinked-#{index}.txt")
      real_link = FileCopyService.method(:native_linkat)
      link_calls = 0

      linking = lambda do |source_fd, source_name, destination_fd, destination_name|
        link_calls += 1
        raise error_class if link_calls == 2

        real_link.call(source_fd, source_name, destination_fd, destination_name)
      end

      FileCopyService.stub(:native_linkat, linking) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end

      assert_equal 2, link_calls
      assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
        [ File.stat(destination).dev, File.stat(destination).ino ]
    end
  end

  test "copy and hardlink locks persist their verified temp identity" do
    copy_destination = File.join(@dest_dir, "copied.txt")
    hardlink_destination = File.join(@dest_dir, "hardlinked.txt")
    real_copy = FileCopyService.method(:copy_source_io)
    real_publish = FileCopyService.method(:publish_private_child_noreplace!)
    verified_copy_lock = false
    verified_hardlink_lock = false

    inspecting_copy = lambda do |source, temporary, heartbeat: nil|
      lock_path = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).sole
      record = FileCopyService::COPY_LOCK_RECORD_PATTERN.match(File.binread(lock_path))
      assert record
      assert_equal [ temporary.stat.dev, temporary.stat.ino ], [ record[2].to_i, record[3].to_i ]
      verified_copy_lock = true
      real_copy.call(source, temporary, heartbeat: heartbeat)
    end
    FileCopyService.stub(:copy_source_io, inspecting_copy) do
      FileCopyService.cp_noreplace(@src_file, copy_destination, root: @dest_dir)
    end

    inspecting_publish = lambda do |parent, temporary_basename, destination_basename, identity, mode:|
      lock_path = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).sole
      record = FileCopyService::COPY_LOCK_RECORD_PATTERN.match(File.binread(lock_path))
      assert record
      assert_equal identity, [ record[2].to_i, record[3].to_i ]
      verified_hardlink_lock = true
      real_publish.call(parent, temporary_basename, destination_basename, identity, mode: mode)
    end
    FileCopyService.stub(:publish_private_child_noreplace!, inspecting_publish) do
      FileCopyService.hardlink_noreplace(
        @src_file,
        hardlink_destination,
        root: @dest_dir,
        source_root: nil
      )
    end

    assert verified_copy_lock
    assert verified_hardlink_lock
  end

  test "copy fsyncs a v2 pending lock before temp creation" do
    destination = File.join(@dest_dir, "copied.txt")
    real_create = FileCopyService.method(:with_created_regular_child)
    verified_pending = false

    inspecting_create = lambda do |parent, basename, mode, &operation|
      if basename.end_with?(".tmp")
        lock_path = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).sole
        record = FileCopyService::COPY_LOCK_PENDING_PATTERN.match(File.binread(lock_path))
        assert record
        verified_pending = true
      end
      real_create.call(parent, basename, mode, &operation)
    end

    FileCopyService.stub(:with_created_regular_child, inspecting_create) do
      FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    end

    assert verified_pending
    assert_equal "test content", File.binread(destination)
  end

  test "hardlink lock persists expected source identity before the initial link" do
    destination = File.join(@dest_dir, "unsupported.txt")
    source_identity = [ File.stat(@src_file).dev, File.stat(@src_file).ino ]
    verified_lock = false

    unsupported_link = lambda do |*|
      lock_path = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).sole
      record = FileCopyService::COPY_LOCK_RECORD_PATTERN.match(File.binread(lock_path))
      assert record
      assert_equal source_identity, [ record[2].to_i, record[3].to_i ]
      verified_lock = true
      raise Errno::EXDEV
    end

    FileCopyService.stub(:native_linkat, unsupported_link) do
      assert_raises(FileCopyService::HardlinkUnsupportedError) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert verified_lock
    assert_equal 1, Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).size
    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)
    assert_empty Dir.children(@dest_dir)
  end

  test "cleanup_interrupted_copies recovers a crash-left private quarantine" do
    token = "a" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    File.binwrite(temporary, "interrupted bytes")
    temporary_stat = File.stat(temporary)
    lock = write_copy_lock(token, temporary_stat)
    quarantine = copy_quarantine_path(temporary_stat, "b" * 32)
    Dir.mkdir(quarantine, 0o700)
    File.rename(temporary, File.join(quarantine, FileCopyService::COPY_QUARANTINE_ENTRY))

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(temporary)
    assert_not File.exist?(lock)
    assert_not File.exist?(quarantine)
  end

  test "cleanup_interrupted_copies retains a fresh empty quarantine" do
    expected_stat = File.stat(@src_file)
    quarantine = copy_quarantine_path(expected_stat, "5" * 32)
    Dir.mkdir(quarantine, 0o700)

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert File.directory?(quarantine)
    assert_empty Dir.children(quarantine)
  end

  test "cleanup_interrupted_copies removes a stale empty private quarantine" do
    expected_stat = File.stat(@src_file)
    quarantine = copy_quarantine_path(expected_stat, "6" * 32)
    Dir.mkdir(quarantine, 0o700)
    stale_time = Time.now - FileCopyService::COPY_QUARANTINE_STALE_AGE - 60
    File.utime(stale_time, stale_time, quarantine)

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(quarantine)
  end

  test "cleanup_interrupted_copies retains stale empty quarantines with wrong owner or mode" do
    expected_stat = File.stat(@src_file)
    owner_quarantine = copy_quarantine_path(expected_stat, "7" * 32)
    mode_quarantine = copy_quarantine_path(expected_stat, "8" * 32)
    Dir.mkdir(owner_quarantine, 0o700)
    Dir.mkdir(mode_quarantine, 0o700)
    File.chmod(0o750, mode_quarantine)
    stale_time = Time.now - FileCopyService::COPY_QUARANTINE_STALE_AGE - 60
    File.utime(stale_time, stale_time, owner_quarantine)
    File.utime(stale_time, stale_time, mode_quarantine)

    Process.stub(:euid, Process.euid + 1) do
      FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)
    end
    assert File.directory?(owner_quarantine)

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(owner_quarantine)
    assert File.directory?(mode_quarantine)
  end

  test "concurrent interrupted cleanup leaves an active empty quarantine in place" do
    target = File.join(@dest_dir, "cleanup-target")
    File.binwrite(target, "cleanup bytes")
    identity = [ File.stat(target).dev, File.stat(target).ino ]
    entered = Queue.new
    release = Queue.new
    real_rename = FileCopyService.method(:native_renameat)
    paused = false
    worker = nil

    pausing_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      if !paused && source_name == File.basename(target) &&
          destination_name == FileCopyService::COPY_QUARANTINE_ENTRY
        paused = true
        entered << true
        release.pop
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_renameat, pausing_rename) do
      FileCopyService.send(
        :with_pinned_destination_parent,
        target,
        root: @dest_dir
      ) do |parent, basename, _parent_path|
        worker = Thread.new do
          FileCopyService.send(:remove_pinned_child_if_identity, parent, basename, identity)
        end
        entered.pop
        quarantine = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*")).sole

        FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

        assert File.directory?(quarantine)
        assert_empty Dir.children(quarantine)
        release << true
        assert_equal :removed, worker.value
      end
    end

    assert_not File.exist?(target)
    assert_empty Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*"))
  ensure
    release << true if release && worker&.alive?
    worker&.join
  end

  test "interrupted cleanup removes an identity-bearing lock when no temp was created" do
    token = "f" * 32
    lock = write_copy_lock(token, File.stat(@src_file))

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(lock)
    assert_empty Dir.children(@dest_dir)
  end

  test "interrupted cleanup removes a compatibility partial by recorded identity" do
    token = "9" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "partial-compatible.txt")
    File.binwrite(temporary, "complete private bytes")
    File.binwrite(destination, "partial")
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      File.stat(destination)
    )

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(temporary)
    assert_not File.exist?(destination)
    assert_not File.exist?(lock)
    assert_empty Dir.children(@dest_dir)
  end

  test "interrupted cleanup retains an unverified prepared compatibility destination" do
    token = "7" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "prepared-compatible.txt")
    File.binwrite(temporary, "complete private bytes")
    File.binwrite(destination, "")
    File.chmod(0o600, destination)
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      File.stat(destination),
      state: :prepared
    )

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "", File.binread(destination)
    assert File.exist?(temporary)
    assert File.exist?(lock)
  end

  test "prepared compatibility cleanup retains a nonempty destination" do
    token = "5" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "prepared-nonempty.txt")
    File.binwrite(temporary, "complete private bytes")
    File.binwrite(destination, "legitimate bytes")
    File.chmod(0o600, destination)
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      File.stat(destination),
      state: :prepared
    )

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "legitimate bytes", File.binread(destination)
    assert File.exist?(temporary)
    assert File.exist?(lock)
  end

  test "interrupted compatibility cleanup retains a destination replacement" do
    token = "0" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "replaced-compatible.txt")
    displaced = File.join(@dest_dir, "original-partial")
    File.binwrite(temporary, "complete private bytes")
    File.binwrite(destination, "owned partial")
    destination_stat = File.stat(destination)
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      destination_stat
    )
    File.rename(destination, displaced)
    File.binwrite(destination, "replacement bytes")

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "replacement bytes", File.binread(destination)
    assert_equal "owned partial", File.binread(displaced)
    assert File.exist?(temporary)
    assert File.exist?(lock)
  end

  test "interrupted compatibility cleanup retains a completed destination" do
    token = "8" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "complete-compatible.txt")
    File.binwrite(temporary, "complete bytes")
    File.binwrite(destination, "complete bytes")
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      File.stat(destination),
      state: :complete
    )

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "complete bytes", File.binread(destination)
    assert_not File.exist?(temporary)
    assert_not File.exist?(lock)
    assert_equal [ "complete-compatible.txt" ], Dir.children(@dest_dir)
  end

  test "interrupted compatibility cleanup uses the last valid journal record" do
    token = "6" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    destination = File.join(@dest_dir, "torn-compatible.txt")
    File.binwrite(temporary, "complete private bytes")
    File.binwrite(destination, "complete private bytes")
    lock = write_compatibility_copy_lock(
      token,
      File.stat(temporary),
      destination,
      File.stat(destination)
    )
    File.open(lock, "ab") do |file|
      file.write(
        "\n#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:compatibility:complete:" \
          "1:2:3:4:746f726e"
      )
    end

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(temporary)
    assert_not File.exist?(destination)
    assert_not File.exist?(lock)
    assert_empty Dir.children(@dest_dir)
  end

  test "interrupted cleanup retains a replacement temp not matching the lock identity" do
    token = "c" * 32
    temporary = File.join(@dest_dir, ".shelfarr-copy-#{token}.tmp")
    displaced = File.join(@dest_dir, "expected-temp")
    File.binwrite(temporary, "expected temp")
    temporary_stat = File.stat(temporary)
    lock = write_copy_lock(token, temporary_stat)
    File.rename(temporary, displaced)
    File.binwrite(temporary, "replacement temp")

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "replacement temp", File.binread(temporary)
    assert_equal "expected temp", File.binread(displaced)
    assert File.exist?(lock)
    assert_empty Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*"))
  end

  test "hardlink ensure removes a verified temp after transient post-link open failure" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    real_open = FileCopyService.method(:with_pinned_regular_child)
    failed = false

    transient_open = lambda do |parent, basename, &operation|
      if !failed && basename.match?(/\A\.shelfarr-copy-.*\.tmp\z/)
        failed = true
        raise Errno::EIO
      end
      real_open.call(parent, basename, &operation)
    end

    FileCopyService.stub(:with_pinned_regular_child, transient_open) do
      assert_raises(Errno::EIO) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert failed
    assert_not File.exist?(destination)
    assert_equal 1, File.stat(@src_file).nlink
    assert_empty Dir.children(@dest_dir)
  end

  test "completed hardlink cleanup retains symlink and directory temp replacements" do
    [ :symlink, :directory ].each do |replacement_type|
      case_directory = File.join(@dest_dir, replacement_type.to_s)
      destination = File.join(case_directory, "hardlinked.txt")
      FileUtils.mkdir_p(case_directory)
      real_validate = FileCopyService.method(:validate_published_child!)
      replacement = nil

      replacing_validate = lambda do |*args, **kwargs|
        result = real_validate.call(*args, **kwargs)
        replacement = Dir.glob(File.join(case_directory, ".shelfarr-copy-*.tmp")).sole
        File.unlink(replacement)
        if replacement_type == :symlink
          File.symlink(@src_file, replacement)
        else
          FileUtils.mkdir_p(replacement)
        end
        result
      end

      FileCopyService.stub(:validate_published_child!, replacing_validate) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end

      assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
        [ File.stat(destination).dev, File.stat(destination).ino ]
      if replacement_type == :symlink
        assert File.symlink?(replacement)
      else
        assert File.directory?(replacement)
      end
      assert_equal 1, Dir.glob(File.join(case_directory, ".shelfarr-copy-*.lock")).size
    end
  end

  test "interrupted cleanup recovers v2 pending and legacy v1 regular temps" do
    pending_token = "d" * 32
    legacy_token = "e" * 32
    pending_temporary = File.join(@dest_dir, ".shelfarr-copy-#{pending_token}.tmp")
    pending_lock = File.join(@dest_dir, ".shelfarr-copy-#{pending_token}.lock")
    legacy_temporary = File.join(@dest_dir, ".shelfarr-copy-#{legacy_token}.tmp")
    legacy_lock = File.join(@dest_dir, ".shelfarr-copy-#{legacy_token}.lock")
    File.binwrite(pending_temporary, "pending temp")
    File.binwrite(pending_lock, "#{FileCopyService::COPY_LOCK_MAGIC}:#{pending_token}:pending")
    File.binwrite(legacy_temporary, "legacy temp")
    File.binwrite(legacy_lock, "#{FileCopyService::COPY_LOCK_LEGACY_MAGIC}:#{legacy_token}")

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_not File.exist?(pending_temporary)
    assert_not File.exist?(pending_lock)
    assert_not File.exist?(legacy_temporary)
    assert_not File.exist?(legacy_lock)
  end

  test "pending and legacy cleanup retain non-regular token replacements" do
    pending_token = "3" * 32
    legacy_token = "4" * 32
    pending_temporary = File.join(@dest_dir, ".shelfarr-copy-#{pending_token}.tmp")
    pending_lock = File.join(@dest_dir, ".shelfarr-copy-#{pending_token}.lock")
    legacy_temporary = File.join(@dest_dir, ".shelfarr-copy-#{legacy_token}.tmp")
    legacy_lock = File.join(@dest_dir, ".shelfarr-copy-#{legacy_token}.lock")
    File.symlink(@src_file, pending_temporary)
    File.binwrite(pending_lock, "#{FileCopyService::COPY_LOCK_MAGIC}:#{pending_token}:pending")
    FileUtils.mkdir_p(legacy_temporary)
    File.binwrite(legacy_lock, "#{FileCopyService::COPY_LOCK_LEGACY_MAGIC}:#{legacy_token}")

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert File.symlink?(pending_temporary)
    assert File.exist?(pending_lock)
    assert File.directory?(legacy_temporary)
    assert File.exist?(legacy_lock)
  end

  test "interrupted cleanup retains malformed locks with temps and removes empty malformed locks" do
    malformed_token = "1" * 32
    empty_token = "2" * 32
    malformed_temporary = File.join(@dest_dir, ".shelfarr-copy-#{malformed_token}.tmp")
    malformed_lock = File.join(@dest_dir, ".shelfarr-copy-#{malformed_token}.lock")
    empty_lock = File.join(@dest_dir, ".shelfarr-copy-#{empty_token}.lock")
    File.binwrite(malformed_temporary, "malformed temp")
    File.binwrite(malformed_lock, "not a copy lock record")
    File.binwrite(empty_lock, "")

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert_equal "malformed temp", File.binread(malformed_temporary)
    assert File.exist?(malformed_lock)
    assert_not File.exist?(empty_lock)
  end

  test "interrupted cleanup retains a mismatched quarantined entry" do
    expected = File.join(@dest_dir, "expected-temp")
    File.binwrite(expected, "expected")
    expected_stat = File.stat(expected)
    quarantine = copy_quarantine_path(expected_stat, "e" * 32)
    Dir.mkdir(quarantine, 0o700)
    entry = File.join(quarantine, FileCopyService::COPY_QUARANTINE_ENTRY)
    File.binwrite(entry, "replacement")
    stale_time = Time.now - FileCopyService::COPY_QUARANTINE_STALE_AGE - 60
    File.utime(stale_time, stale_time, quarantine)

    FileCopyService.cleanup_interrupted_copies(@dest_dir, root: @dest_dir)

    assert File.directory?(quarantine)
    assert_equal "replacement", File.binread(entry)
    assert_equal "expected", File.binread(expected)
  end

  test "cleanup raises and retains a mismatch when no-replace restoration is unsupported" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    displaced = File.join(@dest_dir, "displaced-verified-link")
    real_rename = FileCopyService.method(:native_renameat)
    swapped = false

    racing_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      if !swapped && source_name.match?(/\A\.shelfarr-copy-.*\.tmp\z/) &&
          destination_name == FileCopyService::COPY_QUARANTINE_ENTRY
        swapped = true
        temporary = File.join(@dest_dir, source_name)
        File.rename(temporary, displaced)
        File.binwrite(temporary, "retained replacement")
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    end

    error = FileCopyService.stub(:native_renameat, racing_rename) do
      FileCopyService.stub(:native_rename_noreplace, false) do
        assert_raises(FileCopyService::UnsafePathError) do
          FileCopyService.hardlink_noreplace(
            @src_file,
            destination,
            root: @dest_dir,
            source_root: nil
          )
        end
      end
    end

    quarantine = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*"))
    assert_match(/retained in quarantine/, error.message)
    assert_equal 1, quarantine.size
    assert_equal "retained replacement",
      File.binread(File.join(quarantine.sole, FileCopyService::COPY_QUARANTINE_ENTRY))
    assert_equal "test content", File.binread(displaced)
  end

  test "cleanup raises and retains a mismatch when the original path becomes occupied" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    displaced = File.join(@dest_dir, "displaced-verified-link")
    occupied = nil
    real_rename = FileCopyService.method(:native_renameat)
    swapped = false

    racing_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      if !swapped && source_name.match?(/\A\.shelfarr-copy-.*\.tmp\z/) &&
          destination_name == FileCopyService::COPY_QUARANTINE_ENTRY
        swapped = true
        temporary = File.join(@dest_dir, source_name)
        File.rename(temporary, displaced)
        File.binwrite(temporary, "quarantined replacement")
        result = real_rename.call(source_fd, source_name, destination_fd, destination_name)
        File.binwrite(temporary, "original-path winner")
        occupied = temporary
        result
      else
        real_rename.call(source_fd, source_name, destination_fd, destination_name)
      end
    end

    error = FileCopyService.stub(:native_renameat, racing_rename) do
      assert_raises(FileCopyService::UnsafePathError) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    quarantine = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-quarantine-*"))
    assert_match(/original path is occupied/, error.message)
    assert_equal "original-path winner", File.binread(occupied)
    assert_equal 1, quarantine.size
    assert_equal "quarantined replacement",
      File.binread(File.join(quarantine.sole, FileCopyService::COPY_QUARANTINE_ENTRY))
    assert_equal "test content", File.binread(displaced)
  end

  test "hardlink_noreplace rejects a source pathname swap before final publication" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    displaced_source = File.join(@tmp_dir, "pinned-source.txt")
    real_linkat = FileCopyService.method(:native_linkat)
    first_link = true

    racing_link = lambda do |source_fd, source_name, destination_fd, destination_name|
      if first_link
        first_link = false
        File.rename(@src_file, displaced_source)
        File.binwrite(@src_file, "replacement source")
      end
      real_linkat.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_linkat, racing_link) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_not File.exist?(destination)
    assert_equal "replacement source", File.binread(@src_file)
    assert_equal "test content", File.binread(displaced_source)
    retained_temp = Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.tmp")).sole
    assert_equal "replacement source", File.binread(retained_temp)
    assert_equal 1, Dir.glob(File.join(@dest_dir, ".shelfarr-copy-*.lock")).size
  end

  test "hardlink_noreplace detects a destination ancestor swap before final publication" do
    nested = File.join(@dest_dir, "nested")
    moved = File.join(@dest_dir, "pinned-nested")
    outside = File.join(@tmp_dir, "outside")
    destination = File.join(nested, "hardlinked.txt")
    FileUtils.mkdir_p(nested)
    FileUtils.mkdir_p(outside)
    real_linkat = FileCopyService.method(:native_linkat)
    first_link = true

    racing_link = lambda do |source_fd, source_name, destination_fd, destination_name|
      if first_link
        first_link = false
        File.rename(nested, moved)
        File.symlink(outside, nested)
      end
      real_linkat.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_linkat, racing_link) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_empty Dir.children(moved)
    assert_empty Dir.children(outside)
    assert_equal 1, File.stat(@src_file).nlink
  end

  test "hardlink_noreplace preserves the stable manifest of a snapshotted source" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    destination = File.join(@dest_dir, "chapter.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    expected_manifest = snapshot.entries.fetch("chapter.mp3")

    FileCopyService.hardlink_noreplace(
      source,
      destination,
      root: @dest_dir,
      source_root: snapshot
    )

    current_stat = File.stat(source)
    current_stable_manifest = [
      current_stat.dev,
      current_stat.ino,
      :file,
      current_stat.size,
      current_stat.mtime.to_r,
      current_stat.mode & 0o7777
    ]
    expected_stable_manifest = [ *expected_manifest.first(5), expected_manifest.fetch(6) ]
    assert_equal expected_stable_manifest, current_stable_manifest
    assert_equal [ current_stat.dev, current_stat.ino ],
      [ File.stat(destination).dev, File.stat(destination).ino ]
    assert_equal 2, current_stat.nlink
  end

  test "hardlink_noreplace imports two snapshotted source names for one inode" do
    source_root_path = File.join(@tmp_dir, "download")
    first_source = File.join(source_root_path, "chapter-one.mp3")
    second_source = File.join(source_root_path, "chapter-two.mp3")
    first_destination = File.join(@dest_dir, "chapter-one.mp3")
    second_destination = File.join(@dest_dir, "chapter-two.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(first_source, "shared chapter")
    File.link(first_source, second_source)
    snapshot = FileCopyService.snapshot_source_root(source_root_path)

    FileCopyService.hardlink_noreplace(
      first_source,
      first_destination,
      root: @dest_dir,
      source_root: snapshot
    )
    FileCopyService.hardlink_noreplace(
      second_source,
      second_destination,
      root: @dest_dir,
      source_root: snapshot
    )

    identities = [ first_source, second_source, first_destination, second_destination ].map do |path|
      stat = File.stat(path)
      [ stat.dev, stat.ino ]
    end
    assert_equal 1, identities.uniq.size
    assert_equal 4, File.stat(first_source).nlink
  end

  test "hardlink_noreplace imports one snapshotted source path more than once" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    first_destination = File.join(@dest_dir, "chapter-one.mp3")
    second_destination = File.join(@dest_dir, "chapter-two.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)

    [ first_destination, second_destination ].each do |destination|
      FileCopyService.hardlink_noreplace(
        source,
        destination,
        root: @dest_dir,
        source_root: snapshot
      )
    end

    source_identity = [ File.stat(source).dev, File.stat(source).ino ]
    assert_equal source_identity, [ File.stat(first_destination).dev, File.stat(first_destination).ino ]
    assert_equal source_identity, [ File.stat(second_destination).dev, File.stat(second_destination).ino ]
    assert_equal 3, File.stat(source).nlink
  end

  test "hardlink reconciliation remains valid after EEXIST temp cleanup" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    occupied = File.join(@dest_dir, "occupied.mp3")
    fallback_destination = File.join(@dest_dir, "fallback-copy.mp3")
    retry_destination = File.join(@dest_dir, "retry.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    File.binwrite(occupied, "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)

    assert_raises(Errno::EEXIST) do
      FileCopyService.hardlink_noreplace(
        source,
        occupied,
        root: @dest_dir,
        source_root: snapshot
      )
    end
    assert FileCopyService.same_file_content?(
      source,
      occupied,
      root: @dest_dir,
      source_root: snapshot,
      hardlink_mode: true
    )
    FileCopyService.cp_noreplace(
      source,
      fallback_destination,
      root: @dest_dir,
      source_root: snapshot,
      hardlink_mode: true
    )

    FileCopyService.hardlink_noreplace(
      source,
      retry_destination,
      root: @dest_dir,
      source_root: snapshot
    )

    assert_equal "chapter", File.binread(occupied)
    assert_equal "chapter", File.binread(fallback_destination)
    assert_not_equal [ File.stat(source).dev, File.stat(source).ino ],
      [ File.stat(fallback_destination).dev, File.stat(fallback_destination).ino ]
    assert_equal [ File.stat(source).dev, File.stat(source).ino ],
      [ File.stat(retry_destination).dev, File.stat(retry_destination).ino ]
    assert_equal 2, File.stat(source).nlink
  end

  test "cp_noreplace keeps strict snapshots by default and permits hardlink fallback validation" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    strict_destination = File.join(@dest_dir, "strict.mp3")
    fallback_destination = File.join(@dest_dir, "fallback.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    entries = snapshot.entries.transform_values(&:dup)
    entries.fetch("chapter.mp3")[5] -= 1
    stale_ctime_snapshot = FileCopyService::SourceRoot.new(
      **snapshot.to_h.merge(entries: entries.freeze)
    ).freeze

    assert_raises(Errno::ESTALE) do
      FileCopyService.cp_noreplace(
        source,
        strict_destination,
        root: @dest_dir,
        source_root: stale_ctime_snapshot
      )
    end
    FileCopyService.cp_noreplace(
      source,
      fallback_destination,
      root: @dest_dir,
      source_root: stale_ctime_snapshot,
      hardlink_mode: true
    )

    assert_not File.exist?(strict_destination)
    assert_equal "chapter", File.binread(fallback_destination)
    assert_not_equal [ File.stat(source).dev, File.stat(source).ino ],
      [ File.stat(fallback_destination).dev, File.stat(fallback_destination).ino ]
  end

  test "hardlink_noreplace rejects source mode mutation from its stable snapshot" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    first_destination = File.join(@dest_dir, "chapter-one.mp3")
    second_destination = File.join(@dest_dir, "chapter-two.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    File.chmod(0o644, source)
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    FileCopyService.hardlink_noreplace(
      source,
      first_destination,
      root: @dest_dir,
      source_root: snapshot
    )
    File.chmod(0o600, source)

    assert_raises(Errno::ESTALE) do
      FileCopyService.hardlink_noreplace(
        source,
        second_destination,
        root: @dest_dir,
        source_root: snapshot
      )
    end

    assert_not File.exist?(second_destination)
    assert_equal 0o600, File.stat(first_destination).mode & 0o7777
    assert_equal [ "chapter-one.mp3" ], Dir.children(@dest_dir)
  end

  test "hardlink_noreplace detects stable source fields changed after publication" do
    destination = File.join(@dest_dir, "hardlinked.txt")
    real_validate = FileCopyService.method(:validate_published_child!)

    mutating_validate = lambda do |*args, **kwargs|
      result = real_validate.call(*args, **kwargs)
      stat = File.stat(@src_file)
      File.binwrite(@src_file, "mutated source bytes")
      File.utime(stat.atime, stat.mtime + 2, @src_file)
      result
    end

    FileCopyService.stub(:validate_published_child!, mutating_validate) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.hardlink_noreplace(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_equal [ File.stat(@src_file).dev, File.stat(@src_file).ino ],
      [ File.stat(destination).dev, File.stat(destination).ino ]
    assert_equal "mutated source bytes", File.binread(destination)
    assert_equal [ "hardlinked.txt" ], Dir.children(@dest_dir)
  end

  test "cp_io_noreplace publishes from the caller's pinned descriptor" do
    destination = File.join(@dest_dir, "descriptor-output.txt")

    File.open(@src_file, File::RDONLY | File::NOFOLLOW) do |source|
      FileCopyService.cp_io_noreplace(source, destination, root: @dest_dir)
    end

    assert_equal "test content", File.binread(destination)
    assert_equal 0o640, File.stat(destination).mode & 0o777
  end

  test "same_file_identity returns true for the same inode" do
    destination = File.join(@dest_dir, "hardlink.txt")
    File.link(@src_file, destination)

    assert FileCopyService.same_file_identity?(
      @src_file,
      destination,
      root: @dest_dir,
      source_root: nil
    )
  end

  test "same_file_identity returns false for independent identical content" do
    destination = File.join(@dest_dir, "copy.txt")
    File.binwrite(destination, "test content")

    assert_not FileCopyService.same_file_identity?(
      @src_file,
      destination,
      root: @dest_dir,
      source_root: nil
    )
  end

  test "same_file_identity returns false for missing symlink and unsafe destinations" do
    missing = File.join(@dest_dir, "missing.txt")
    symlink = File.join(@dest_dir, "symlink.txt")
    directory = File.join(@dest_dir, "directory")
    File.symlink(@src_file, symlink)
    FileUtils.mkdir_p(directory)

    [ missing, symlink, directory ].each do |destination|
      assert_not FileCopyService.same_file_identity?(
        @src_file,
        destination,
        root: @dest_dir,
        source_root: nil
      )
    end
  end

  test "same_file_identity uses hardlink-stable snapshot validation after link-count changes" do
    source_root_path = File.join(@tmp_dir, "download")
    source = File.join(source_root_path, "chapter.mp3")
    destination = File.join(@dest_dir, "chapter.mp3")
    FileUtils.mkdir_p(source_root_path)
    File.binwrite(source, "chapter")
    snapshot = FileCopyService.snapshot_source_root(source_root_path)
    File.link(source, destination)

    assert FileCopyService.same_file_identity?(
      source,
      destination,
      root: @dest_dir,
      source_root: snapshot,
      hardlink_mode: true
    )
  end

  test "same_file_identity rejects a destination pathname swap during revalidation" do
    destination = File.join(@dest_dir, "hardlink.txt")
    displaced = File.join(@dest_dir, "displaced-hardlink.txt")
    File.link(@src_file, destination)
    real_open = FileCopyService.method(:with_pinned_regular_child)
    destination_opens = 0

    swapping_open = lambda do |parent, basename, &operation|
      result = real_open.call(parent, basename, &operation)
      if basename == File.basename(destination)
        destination_opens += 1
        if destination_opens == 1
          File.rename(destination, displaced)
          File.binwrite(destination, "replacement")
        end
      end
      result
    end

    FileCopyService.stub(:with_pinned_regular_child, swapping_open) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.same_file_identity?(
          @src_file,
          destination,
          root: @dest_dir,
          source_root: nil
        )
      end
    end

    assert_equal "replacement", File.binread(destination)
    assert_equal "test content", File.binread(displaced)
  end

  test "secure_library_file_mode checks a pinned revalidated regular file" do
    destination = File.join(@dest_dir, "library.txt")
    symlink = File.join(@dest_dir, "library-link.txt")
    File.binwrite(destination, "library")
    File.chmod(FileCopyService::LIBRARY_FILE_MODE, destination)
    File.symlink(destination, symlink)

    assert FileCopyService.secure_library_file_mode?(destination, root: @dest_dir)
    assert_not FileCopyService.secure_library_file_mode?(symlink, root: @dest_dir)
    File.chmod(0o644, destination)
    assert_not FileCopyService.secure_library_file_mode?(destination, root: @dest_dir)
  end

  test "secure_library_file_mode rejects a destination swap during revalidation" do
    destination = File.join(@dest_dir, "library.txt")
    displaced = File.join(@dest_dir, "displaced-library.txt")
    File.binwrite(destination, "library")
    File.chmod(FileCopyService::LIBRARY_FILE_MODE, destination)
    real_open = FileCopyService.method(:with_pinned_regular_child)
    destination_opens = 0

    swapping_open = lambda do |parent, basename, &operation|
      result = real_open.call(parent, basename, &operation)
      if basename == File.basename(destination)
        destination_opens += 1
        if destination_opens == 1
          File.rename(destination, displaced)
          File.binwrite(destination, "replacement")
          File.chmod(FileCopyService::LIBRARY_FILE_MODE, destination)
        end
      end
      result
    end

    FileCopyService.stub(:with_pinned_regular_child, swapping_open) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.secure_library_file_mode?(destination, root: @dest_dir)
      end
    end

    assert_equal "replacement", File.binread(destination)
    assert_equal "library", File.binread(displaced)
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

  test "remove_source_file retains an in-place mutation after snapshot" do
    snapshot = FileCopyService.snapshot_source_file(@src_file)
    File.binwrite(@src_file, "other bytes!")

    assert_not FileCopyService.remove_source_file(snapshot)
    assert_equal "other bytes!", File.binread(@src_file)
  end

  test "remove_source_file restores a replacement that wins before quarantine" do
    snapshot = FileCopyService.snapshot_source_file(@src_file)
    displaced = File.join(@tmp_dir, "original-source")
    real_rename = FileCopyService.method(:native_renameat)
    swapped = false

    racing_rename = lambda do |source_fd, source_name, destination_fd, destination_name|
      if !swapped && source_name == File.basename(@src_file) &&
          destination_name == FileCopyService::COPY_QUARANTINE_ENTRY
        swapped = true
        File.rename(@src_file, displaced)
        File.binwrite(@src_file, "replacement bytes")
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    end

    FileCopyService.stub(:native_renameat, racing_rename) do
      assert_not FileCopyService.remove_source_file(snapshot)
    end

    assert_equal "replacement bytes", File.binread(@src_file)
    assert_equal "test content", File.binread(displaced)
  end

  test "remove_source_file restores its source when quarantine unlink fails" do
    snapshot = FileCopyService.snapshot_source_file(@src_file)
    real_unlink = FileCopyService.method(:native_unlinkat)

    unlinking = lambda do |directory_fd, basename, flags = 0|
      raise Errno::EIO if basename == FileCopyService::COPY_QUARANTINE_ENTRY

      real_unlink.call(directory_fd, basename, flags)
    end

    FileCopyService.stub(:native_unlinkat, unlinking) do
      assert_raises(Errno::EIO) { FileCopyService.remove_source_file(snapshot) }
    end

    assert_equal "test content", File.binread(@src_file)
    assert_empty Dir.glob(File.join(@tmp_dir, ".shelfarr-source-quarantine-*"))
  end

  test "remove_source_file recovers a source quarantined by a hard interruption" do
    snapshot = FileCopyService.snapshot_source_file(@src_file)
    real_unlink = FileCopyService.method(:native_unlinkat)
    interrupted = false

    unlinking = lambda do |directory_fd, basename, flags = 0|
      if !interrupted && basename == FileCopyService::COPY_QUARANTINE_ENTRY
        interrupted = true
        raise Interrupt, "simulated hard interruption"
      end

      real_unlink.call(directory_fd, basename, flags)
    end

    FileCopyService.stub(:native_unlinkat, unlinking) do
      assert_raises(Interrupt) { FileCopyService.remove_source_file(snapshot) }
    end
    assert_not File.exist?(@src_file)
    assert_equal 1, Dir.glob(File.join(@tmp_dir, ".shelfarr-source-quarantine-*")).size

    assert FileCopyService.remove_source_file(snapshot)
    assert_empty Dir.glob(File.join(@tmp_dir, ".shelfarr-source-quarantine-*"))
  end

  test "remove_source_file reports a source retained in quarantine behind a replacement" do
    destination = File.join(@dest_dir, "verified-quarantine.txt")
    FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    destination_snapshot = FileCopyService.verified_library_file_snapshot(
      @src_file,
      destination,
      root: @dest_dir,
      require_durable: true
    )
    source_snapshot = FileCopyService.snapshot_source_file(@src_file)
    real_unlink = FileCopyService.method(:native_unlinkat)
    interrupted = false

    unlinking = lambda do |directory_fd, basename, flags = 0|
      if !interrupted && basename == FileCopyService::COPY_QUARANTINE_ENTRY
        interrupted = true
        raise Interrupt, "simulated hard interruption"
      end

      real_unlink.call(directory_fd, basename, flags)
    end
    FileCopyService.stub(:native_unlinkat, unlinking) do
      assert_raises(Interrupt) do
        FileCopyService.remove_source_file(
          source_snapshot,
          destination_snapshot: destination_snapshot
        )
      end
    end

    replacement = File.join(@tmp_dir, "replacement.txt")
    File.binwrite(replacement, "replacement source")
    File.symlink(replacement, @src_file)
    File.binwrite(destination, "changed destination")

    assert_not FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )
    assert FileCopyService.source_file_quarantined?(source_snapshot)
    assert_equal "replacement source", File.binread(@src_file)
  end

  test "remove_source_file does not report success when its snapshotted parent moved" do
    parent = File.join(@tmp_dir, "source-parent")
    displaced = File.join(@tmp_dir, "displaced-source-parent")
    FileUtils.mkdir_p(parent)
    source = File.join(parent, "book.epub")
    File.binwrite(source, "source bytes")
    snapshot = FileCopyService.snapshot_source_file(source)
    File.rename(parent, displaced)

    assert_not FileCopyService.remove_source_file(snapshot)
    assert_equal "source bytes", File.binread(File.join(displaced, "book.epub"))
  end

  test "remove_source_file restores a quarantined source when its destination changed" do
    destination = File.join(@dest_dir, "verified.txt")
    FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    destination_snapshot = FileCopyService.verified_library_file_snapshot(
      @src_file,
      destination,
      root: @dest_dir,
      require_durable: true
    )
    source_snapshot = FileCopyService.snapshot_source_file(@src_file)
    File.binwrite(destination, "changed bytes")

    assert_not FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )

    assert_equal "test content", File.binread(@src_file)
    assert_equal "changed bytes", File.binread(destination)
  end

  test "remove_source_file validates the destination when the source is already missing" do
    destination = File.join(@dest_dir, "missing-source-destination.txt")
    FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    destination_snapshot = FileCopyService.verified_library_file_snapshot(
      @src_file,
      destination,
      root: @dest_dir,
      require_durable: true
    )
    source_snapshot = FileCopyService.snapshot_source_file(@src_file)
    File.unlink(@src_file)
    File.binwrite(destination, "changed destination")

    assert_not FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )
  end

  test "file snapshot validation rejects a destination replaced during fsync" do
    destination = File.join(@dest_dir, "sync-replaced-destination.txt")
    displaced = File.join(@dest_dir, "sync-displaced-destination.txt")
    FileCopyService.cp_noreplace(@src_file, destination, root: @dest_dir)
    snapshot = FileCopyService.verified_library_file_snapshot(
      @src_file,
      destination,
      root: @dest_dir,
      require_durable: true
    )
    destination_identity = [ File.stat(destination).dev, File.stat(destination).ino ]
    real_sync = FileCopyService.method(:sync_io)
    replaced = false

    syncing = lambda do |io|
      result = real_sync.call(io)
      if !replaced && io.stat.file? && [ io.stat.dev, io.stat.ino ] == destination_identity
        replaced = true
        File.rename(destination, displaced)
        File.binwrite(destination, "replacement during fsync")
      end
      result
    end

    result = FileCopyService.stub(:sync_io, syncing) do
      FileCopyService.file_snapshot_current?(snapshot, require_durable: true)
    end

    assert replaced
    assert_not result
    assert_equal "replacement during fsync", File.binread(destination)
    assert_equal "test content", File.binread(displaced)
  end

  test "remove_source_file is idempotent when the source is already missing" do
    snapshot = FileCopyService.snapshot_source_file(@src_file)
    File.unlink(@src_file)

    assert FileCopyService.remove_source_file(snapshot)
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

  test "mv_noreplace preserves a source replacement before source removal" do
    dest_file = File.join(@dest_dir, "output.txt")
    real_remove = FileCopyService.method(:remove_source_file)

    FileCopyService.stub(:remove_source_file, ->(source_snapshot, destination_snapshot:) {
      File.unlink(@src_file)
      File.binwrite(@src_file, "concurrent source replacement")
      real_remove.call(source_snapshot, destination_snapshot: destination_snapshot)
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.mv_noreplace(@src_file, dest_file)
      end
    end

    assert_equal "test content", File.binread(dest_file)
    assert_equal "concurrent source replacement", File.binread(@src_file)
  end

  test "mv_noreplace retains its source when the destination changes before removal" do
    destination = File.join(@dest_dir, "replaced-output.txt")
    displaced = File.join(@dest_dir, "original-output.txt")
    real_remove = FileCopyService.method(:remove_source_file)

    FileCopyService.stub(:remove_source_file, ->(source_snapshot, destination_snapshot:) {
      File.rename(destination, displaced)
      File.binwrite(destination, "concurrent destination replacement")
      real_remove.call(source_snapshot, destination_snapshot: destination_snapshot)
    }) do
      assert_raises(Errno::ESTALE) do
        FileCopyService.mv_noreplace(@src_file, destination, root: @dest_dir)
      end
    end

    assert_equal "test content", File.binread(@src_file)
    assert_equal "concurrent destination replacement", File.binread(destination)
    assert_equal "test content", File.binread(displaced)
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

  private

  def write_copy_lock(token, temporary_stat)
    lock = File.join(@dest_dir, ".shelfarr-copy-#{token}.lock")
    File.binwrite(
      lock,
      "#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:full:#{temporary_stat.dev}:#{temporary_stat.ino}"
    )
    lock
  end

  def write_compatibility_copy_lock(token, temporary_stat, destination, destination_stat, state: :copying)
    lock = File.join(@dest_dir, ".shelfarr-copy-#{token}.lock")
    encoded_basename = File.basename(destination).b.unpack1("H*")
    record = "#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:compatibility:#{state}:" \
      "#{temporary_stat.dev}:#{temporary_stat.ino}:"
    unless state == :prepared
      record << "#{destination_stat.dev}:#{destination_stat.ino}:"
    end
    record << encoded_basename
    checksum = Digest::SHA256.hexdigest(record)
    File.binwrite(
      lock,
      "#{record}:#{checksum}\n"
    )
    lock
  end

  def without_atomic_file_publication(&operation)
    FileCopyService.stub(:native_linkat, ->(*) { raise Errno::EOPNOTSUPP }) do
      FileCopyService.stub(:native_rename_noreplace, false, &operation)
    end
  end

  def copy_quarantine_path(expected_stat, token)
    File.join(
      @dest_dir,
      ".shelfarr-copy-quarantine-#{expected_stat.dev.to_s(16)}-#{expected_stat.ino.to_s(16)}-#{token}"
    )
  end
end
