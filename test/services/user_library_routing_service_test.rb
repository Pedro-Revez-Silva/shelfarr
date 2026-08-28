# frozen_string_literal: true

require "test_helper"

class UserLibraryRoutingServiceTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("shelfarr_routing_test_")
    @global_base = File.join(@tmpdir, "audiobooks")
    @user_dir = File.join(@tmpdir, "user_output")
    FileUtils.mkdir_p(@global_base)

    @user = users(:one)
    @book = books(:audiobook_acquired)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Helper: build a request object without persisting it ──────────────────

  def build_request
    @user.requests.build(book: @book, status: :pending)
  end

  # ── Helper: configure user for routing ────────────────────────────────────

  def configure_user(mode:)
    @user.update!(preferred_output_path: @user_dir, library_routing_mode: mode)
  end

  # ── Helper: point the book at a real path inside the temp dir ─────────────

  def set_book_file_path(path)
    @book.update!(file_path: path)
  end

  # ── No-op cases ───────────────────────────────────────────────────────────

  test "does nothing when user has no preferred_output_path" do
    @user.update!(preferred_output_path: nil, library_routing_mode: "copy")
    set_book_file_path(File.join(@global_base, "some_book.epub"))

    assert_no_difference "UserBookPath.count" do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end
  end

  test "does nothing when user has no library_routing_mode" do
    @user.update!(preferred_output_path: @user_dir, library_routing_mode: nil)
    set_book_file_path(File.join(@global_base, "some_book.epub"))

    assert_no_difference "UserBookPath.count" do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end
  end

  test "does nothing when book has no file_path" do
    configure_user(mode: "copy")
    @book.update!(file_path: nil)

    assert_no_difference "UserBookPath.count" do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end
  end

  # ── Copy mode: single file ─────────────────────────────────────────────────

  test "copy mode duplicates a single file into the user directory" do
    source_file = File.join(@global_base, "author", "book.epub")
    FileUtils.mkdir_p(File.dirname(source_file))
    File.write(source_file, "epub content")
    set_book_file_path(source_file)
    configure_user(mode: "copy")

    expected_dest = File.join(@user_dir, "author", "book.epub")

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end

    assert File.exist?(expected_dest), "Expected copy at #{expected_dest}"
    assert_equal "epub content", File.read(expected_dest)
  end

  test "copy mode creates a UserBookPath record" do
    source_file = File.join(@global_base, "book.epub")
    File.write(source_file, "epub content")
    set_book_file_path(source_file)
    configure_user(mode: "copy")

    assert_difference "UserBookPath.count", 1 do
      SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
        UserLibraryRoutingService.call(book: @book, request: build_request)
      end
    end

    record = UserBookPath.find_by(user: @user, book: @book)
    assert_not_nil record
    assert record.file_path.start_with?(@user_dir)
  end

  # ── Copy mode: directory (audiobook) ──────────────────────────────────────

  test "copy mode duplicates a directory of files into the user directory" do
    source_dir = File.join(@global_base, "author", "audiobook")
    FileUtils.mkdir_p(source_dir)
    File.write(File.join(source_dir, "chapter1.mp3"), "audio1")
    File.write(File.join(source_dir, "chapter2.mp3"), "audio2")
    set_book_file_path(source_dir)
    configure_user(mode: "copy")

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end

    dest_dir = File.join(@user_dir, "author", "audiobook")
    assert File.directory?(dest_dir), "Expected destination directory at #{dest_dir}"
    assert File.exist?(File.join(dest_dir, "chapter1.mp3"))
    assert File.exist?(File.join(dest_dir, "chapter2.mp3"))
  end

  # ── Hardlink mode: single file ─────────────────────────────────────────────

  test "hardlink mode creates a hard link sharing the same inode" do
    source_file = File.join(@global_base, "author", "book.epub")
    FileUtils.mkdir_p(File.dirname(source_file))
    File.write(source_file, "epub content")
    set_book_file_path(source_file)
    configure_user(mode: "hardlink")

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end

    dest_file = File.join(@user_dir, "author", "book.epub")
    assert File.exist?(dest_file), "Expected hard link at #{dest_file}"
    assert_equal File.stat(source_file).ino, File.stat(dest_file).ino,
      "Hard link should share the same inode as the source"
  end

  # ── Hardlink mode: directory ───────────────────────────────────────────────

  test "hardlink mode walks a directory and hard-links each file" do
    source_dir = File.join(@global_base, "audiobook")
    FileUtils.mkdir_p(source_dir)
    File.write(File.join(source_dir, "part1.mp3"), "audio")
    set_book_file_path(source_dir)
    configure_user(mode: "hardlink")

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
      UserLibraryRoutingService.call(book: @book, request: build_request)
    end

    dest_file = File.join(@user_dir, "audiobook", "part1.mp3")
    assert File.exist?(dest_file)
    assert_equal File.stat(File.join(source_dir, "part1.mp3")).ino, File.stat(dest_file).ino
  end

  # ── Hardlink EXDEV fallback ────────────────────────────────────────────────

  test "hardlink mode falls back to copy on cross-device error" do
    source_file = File.join(@global_base, "book.epub")
    File.write(source_file, "epub bytes")
    set_book_file_path(source_file)
    configure_user(mode: "hardlink")

    # Simulate a cross-device link error (different filesystem)
    File.stub(:link, ->(*_args) { raise Errno::EXDEV, "cross-device link" }) do
      SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
        UserLibraryRoutingService.call(book: @book, request: build_request)
      end
    end

    dest_file = File.join(@user_dir, "book.epub")
    assert File.exist?(dest_file), "Expected fallback copy at #{dest_file}"
    assert_equal "epub bytes", File.read(dest_file)
  end

  # ── Idempotency ────────────────────────────────────────────────────────────

  test "calling twice does not create duplicate UserBookPath records" do
    source_file = File.join(@global_base, "book.epub")
    File.write(source_file, "epub content")
    set_book_file_path(source_file)
    configure_user(mode: "copy")

    assert_difference "UserBookPath.count", 1 do
      2.times do
        SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
          UserLibraryRoutingService.call(book: @book, request: build_request)
        end
      end
    end
  end

  # ── Error resilience ───────────────────────────────────────────────────────

  test "does not raise when a filesystem error occurs" do
    configure_user(mode: "copy")
    set_book_file_path(File.join(@global_base, "nonexistent", "book.epub"))

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_base }) do
      assert_nothing_raised do
        UserLibraryRoutingService.call(book: @book, request: build_request)
      end
    end
  end
end
