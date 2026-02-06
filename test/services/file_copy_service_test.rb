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
