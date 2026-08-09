# frozen_string_literal: true

require "test_helper"

class FilesystemSyscallsTest < ActiveSupport::TestCase
  setup do
    @temporary_directory = Dir.mktmpdir("filesystem-syscalls-test")
    @directory = File.open(@temporary_directory, File::RDONLY | File::NONBLOCK)
  end

  teardown do
    @directory.close unless @directory.closed?
    FileUtils.remove_entry(@temporary_directory)
  end

  test "openat creates a file with the supplied mode" do
    descriptor = FilesystemSyscalls.openat(
      @directory.fileno,
      "created.txt",
      flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
      mode: 0o600
    )
    file = IO.new(descriptor, "wb", autoclose: true)
    file.write("content")
    file.close

    path = File.join(@temporary_directory, "created.txt")
    assert_equal "content", File.binread(path)
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  test "openat passes the mode required by O_TMPFILE" do
    skip "O_TMPFILE is unavailable on this platform" unless File.const_defined?(:TMPFILE)

    descriptor = FilesystemSyscalls.openat(
      @directory.fileno,
      ".",
      flags: File::RDWR | File::TMPFILE,
      mode: 0o600
    )
    file = IO.new(descriptor, "w+b", autoclose: true)

    assert_equal 0o600, file.stat.mode & 0o777
  rescue Errno::EOPNOTSUPP, Errno::EINVAL
    skip "The test filesystem does not support O_TMPFILE"
  ensure
    file&.close unless file&.closed?
  end

  test "path operations reject embedded null bytes" do
    assert_raises(ArgumentError) do
      FilesystemSyscalls.openat(
        @directory.fileno,
        "prefix\0suffix",
        flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
        mode: 0o600
      )
    end

    assert_not File.exist?(File.join(@temporary_directory, "prefix"))
  end

  test "rename_noreplace publishes once without replacing an existing path" do
    File.binwrite(File.join(@temporary_directory, "source.txt"), "source")

    published = FilesystemSyscalls.rename_noreplace(
      @directory.fileno,
      "source.txt",
      @directory.fileno,
      "destination.txt"
    )
    skip "No native no-replace rename is available on this platform" unless published

    File.binwrite(File.join(@temporary_directory, "second.txt"), "second")
    assert_raises(Errno::EEXIST) do
      FilesystemSyscalls.rename_noreplace(
        @directory.fileno,
        "second.txt",
        @directory.fileno,
        "destination.txt"
      )
    end
    assert_equal "source", File.binread(File.join(@temporary_directory, "destination.txt"))
    assert_equal "second", File.binread(File.join(@temporary_directory, "second.txt"))
  end

  test "rename_noreplace preserves invalid topology errors" do
    parent = File.join(@temporary_directory, "parent")
    child = File.join(parent, "child")
    FileUtils.mkdir_p(child)
    child_directory = File.open(child, File::RDONLY | File::NONBLOCK)

    assert_raises(Errno::EINVAL) do
      FilesystemSyscalls.rename_noreplace(
        @directory.fileno,
        "parent",
        child_directory.fileno,
        "moved"
      )
    end
  ensure
    child_directory&.close unless child_directory&.closed?
  end

  test "ftruncate preserves lengths beyond a signed 32-bit offset" do
    skip "Shelfarr supports 64-bit filesystem offsets" if Fiddle::SIZEOF_LONG < 8

    descriptor = FilesystemSyscalls.openat(
      @directory.fileno,
      "sparse.bin",
      flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
      mode: 0o600
    )
    file = IO.new(descriptor, "wb", autoclose: true)
    length = (2**31) + 1
    FilesystemSyscalls.ftruncate(file.fileno, length)

    assert_equal length, file.stat.size
  ensure
    file&.close unless file&.closed?
  end
end
