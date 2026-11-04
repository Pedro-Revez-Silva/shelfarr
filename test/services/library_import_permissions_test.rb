# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class LibraryImportPermissionsTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("library-permissions"))
    @outside = Pathname(Dir.mktmpdir("library-permissions-outside"))
    SettingsService.set(:library_import_file_mode, "")
    SettingsService.set(:library_import_folder_mode, "")
  end

  teardown do
    FileUtils.rm_rf(@root)
    FileUtils.rm_rf(@outside)
  end

  test "blank modes leave an imported file and its folders untouched" do
    file = write_file(@root.join("Author", "Title", "book.mp3"), 0o640)
    File.chmod(0o750, file.dirname)
    File.chmod(0o750, file.dirname.dirname)

    LibraryImportPermissions.apply_file!(file.to_s, root: @root.to_s)
    LibraryImportPermissions.apply_directory!(file.dirname.to_s, root: @root.to_s)

    assert_equal 0o640, file.stat.mode & 0o777
    assert_equal 0o750, file.dirname.stat.mode & 0o777
  end

  test "file and folder modes are applied inside the library and the root is unchanged" do
    SettingsService.set(:library_import_file_mode, "0664")
    SettingsService.set(:library_import_folder_mode, "0775")
    file = write_file(@root.join("Author", "Title", "book.mp3"), 0o640)
    root_mode = @root.stat.mode & 0o777

    LibraryImportPermissions.apply_file!(file.to_s, root: @root.to_s)
    LibraryImportPermissions.apply_directory!(file.dirname.to_s, root: @root.to_s)

    assert_equal 0o664, file.stat.mode & 0o777
    assert_equal 0o775, file.dirname.stat.mode & 0o777
    assert_equal 0o775, file.dirname.dirname.stat.mode & 0o777
    assert_equal root_mode, @root.stat.mode & 0o777
  end

  test "a shared inode is skipped without a caller hint" do
    SettingsService.set(:library_import_file_mode, "0664")
    source = write_file(@outside.join("download.mp3"), 0o604)
    destination = @root.join("Author", "Title", "book.mp3")
    FileUtils.mkdir_p(destination.dirname)
    File.link(source, destination)
    target = destination.expand_path
    real_stat = File.method(:stat)
    real_lstat = File.method(:lstat)
    lie = lambda do |method, path|
      stat = method.call(path)
      stat.define_singleton_method(:nlink) { 1 } if Pathname(path).expand_path == target
      stat
    end

    File.stub(:stat, ->(path) { lie.call(real_stat, path) }) do
      File.stub(:lstat, ->(path) { lie.call(real_lstat, path) }) do
        LibraryImportPermissions.apply_file!(destination.to_s, root: @root.to_s)
      end
    end

    assert_operator destination.stat.nlink, :>, 1
    assert_equal 0o604, source.stat.mode & 0o777
    assert_equal 0o604, destination.stat.mode & 0o777
  end

  test "a tree skips files with extra links and does not follow symlinks" do
    SettingsService.set(:library_import_file_mode, "0664")
    SettingsService.set(:library_import_folder_mode, "0775")
    tree = @root.join("Author", "Title")
    regular = write_file(tree.join("chapter.mp3"), 0o640)
    linked = write_file(tree.join("shared.mp3"), 0o604)
    File.link(linked, tree.join("shared-link.mp3"))
    outside = write_file(@outside.join("secret.mp3"), 0o600)
    File.symlink(outside, tree.join("linked.mp3"))
    root_mode = @root.stat.mode & 0o777

    LibraryImportPermissions.apply_tree!(tree.to_s, root: @root.to_s)

    assert_equal 0o664, regular.stat.mode & 0o777
    assert_equal 0o604, linked.stat.mode & 0o777
    assert_equal 0o600, outside.stat.mode & 0o777
    assert_equal 0o775, tree.stat.mode & 0o777
    assert_equal 0o775, tree.dirname.stat.mode & 0o777
    assert_equal root_mode, @root.stat.mode & 0o777
  end

  test "chmod failures are warnings and do not raise" do
    SettingsService.set(:library_import_file_mode, "0664")
    SettingsService.set(:library_import_folder_mode, "0775")
    file = write_file(@root.join("Author", "book.mp3"), 0o640)
    unsupported = nil
    begin
      raise Errno::EOPNOTSUPP, "nfs"
    rescue SystemCallError => error
      unsupported = error
    end
    FileCopyService.stub(:chmod_nofollow, ->(*) { raise unsupported }) do
      capture_warning(unsupported.class) do
        result = LibraryImportPermissions.apply_file!(file.to_s, root: @root.to_s)
        assert_kind_of RemoteResult::Failed, result
        assert_nil LibraryImportPermissions.apply_directory!(file.dirname.to_s, root: @root.to_s)
        assert_nil LibraryImportPermissions.apply_tree!(file.dirname.to_s, root: @root.to_s)
      end
    end

    assert_equal 0o640, file.stat.mode & 0o777
  end

  private

  def write_file(path, mode)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "bytes")
    File.chmod(mode, path)
    path
  end

  def capture_warning(error_class)
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    Rails.stub(:logger, logger) { yield }
    assert_includes output.string, "Could not apply the configured library import mode (#{error_class})"
    refute_includes output.string, @root.to_s
  end
end
