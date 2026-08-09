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

  test "ftruncate preserves lengths beyond a signed 32-bit offset" do
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
