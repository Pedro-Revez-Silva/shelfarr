# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "zip"

class DirectDownloadArchiveExtractorTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    @destination = FileCopyService.create_private_directory(
      @root,
      root: @root,
      prefix: "extracted-"
    ).name
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "extracts regular files and empty directories beneath the pinned root" do
    with_archive("disc/chapter.mp3" => "audio", "empty/" => nil) do |source|
      assert build_extractor(source).extract!
    end

    assert_equal "audio", File.binread(File.join(@destination, "disc", "chapter.mp3"))
    assert File.directory?(File.join(@destination, "empty"))
    assert_equal 0o600, File.stat(File.join(@destination, "disc", "chapter.mp3")).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@destination, "disc")).mode & 0o777
  end

  test "an ancestor swap during extraction never redirects bytes outside staging" do
    moved = File.join(@root, "pinned-extracted")
    outside = File.join(@root, "outside")
    FileUtils.mkdir_p(outside)
    original_sync = FileCopyService.method(:flush_and_sync)
    swapped = false

    with_archive("chapter.mp3" => "complete audio") do |source|
      FileCopyService.stub(:flush_and_sync, lambda { |io|
        original_sync.call(io)
        unless swapped
          swapped = true
          File.rename(@destination, moved)
          File.symlink(outside, @destination)
        end
      }) do
        assert_raises(DirectDownloadArchiveExtractor::Error) do
          build_extractor(source).extract!
        end
      end
    end

    assert_empty Dir.children(outside)
    assert File.directory?(moved)
  ensure
    FileUtils.rm_f(@destination) if @destination && File.symlink?(@destination)
  end

  test "a FIFO injected at an archive pathname is preserved and never opened" do
    skip "mkfifo is unavailable" unless File.respond_to?(:mkfifo)

    fifo = File.join(@destination, "chapter.mp3")
    File.mkfifo(fifo, 0o600)

    with_archive("chapter.mp3" => "audio") do |source|
      assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source).extract!
      end
    end

    assert File.stat(fifo).pipe?
  end

  test "rejects symbolic-link and special archive metadata before writing" do
    fake_entry = Struct.new(:name, :symlink?, :directory?, :file?)

    with_archive("seed.mp3" => "audio") do |source|
      [
        fake_entry.new("link", true, false, true),
        fake_entry.new("device", false, false, false)
      ].each do |entry|
        archive = Struct.new(:entries).new([ entry ])
        Zip::File.stub(:open, ->(_path, &block) { block.call(archive) }) do
          assert_raises(DirectDownloadArchiveExtractor::Error) do
            build_extractor(source).extract!
          end
        end
      end
    end

    assert_empty Dir.children(@destination)
  end

  test "rejects entry counts above the configured archive cap before writing" do
    fake_entry = Struct.new(:name, :symlink?, :directory?, :file?)
    entries = 101.times.map { |index| fake_entry.new("chapter-#{index}.mp3", false, false, true) }
    archive = Struct.new(:entries).new(entries)

    with_archive("seed.mp3" => "audio") do |source|
      Zip::File.stub(:open, ->(_path, &block) { block.call(archive) }) do
        assert_raises(DirectDownloadArchiveExtractor::Error) do
          build_extractor(source).extract!
        end
      end
    end

    assert_empty Dir.children(@destination)
  end

  test "preflights the declared and actual central entry count before rubyzip opens" do
    Tempfile.create([ "direct-preflight-", ".zip" ]) do |archive|
      path = archive.path
      archive.close
      Zip::File.open(path, create: true) do |zipfile|
        zipfile.get_output_stream("first.mp3") { |stream| stream.write("one") }
        zipfile.get_output_stream("second.mp3") { |stream| stream.write("two") }
      end
      bytes = File.binread(path)
      end_record = bytes.rindex(ZipArchivePreflightService::END_OF_CENTRAL_DIRECTORY_SIGNATURE)
      bytes[end_record + 8, 4] = [ 1, 1 ].pack("vv")
      File.binwrite(path, bytes)

      File.open(path, "rb") do |source|
        Zip::File.stub(:open, ->(*) { flunk "rubyzip opened an archive that failed preflight" }) do
          error = assert_raises(DirectDownloadArchiveExtractor::Error) do
            build_extractor(source).extract!
          end
          assert_includes error.message, "entry count"
        end
      end
    end

    assert_empty Dir.children(@destination)
  end

  test "rejects implicit directory amplification before creating any output" do
    entries = {
      "one/two/three/chapter.mp3" => "one",
      "four/five/six/chapter.mp3" => "two"
    }

    with_archive(entries) do |source|
      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source, max_entries: 2).extract!
      end
      assert_includes error.message, "too many files and directories"
    end

    assert_empty Dir.children(@destination)
  end

  test "rejects an entry whose streamed bytes do not match its declared CRC" do
    with_archive("chapter.mp3" => "audio") do |source|
      mutate_entry_fields(source.path) do |bytes, central, local|
        bytes[central + 16, 4] = [ 0 ].pack("V")
        bytes[local + 14, 4] = [ 0 ].pack("V")
      end

      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source).extract!
      end
      assert_includes error.message, "CRC validation"
    end
  end

  test "stops when an entry inflates beyond its declared size" do
    with_archive("chapter.mp3" => "audio") do |source|
      mutate_entry_fields(source.path) do |bytes, central, local|
        bytes[central + 24, 4] = [ 1 ].pack("V")
        bytes[local + 22, 4] = [ 1 ].pack("V")
      end

      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source).extract!
      end
      assert_includes error.message, "declared size"
    end
  end

  test "rejects files outside the explicitly allowed extensions" do
    with_archive("chapter.mp3" => "audio", "cover.html" => "payload") do |source|
      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source, allowed_file_extensions: %w[mp3]).extract!
      end
      assert_includes error.message, "unsupported file type"
    end

    assert_not File.exist?(File.join(@destination, "chapter.mp3"))
    assert_not File.exist?(File.join(@destination, "cover.html"))
  end

  test "enforces a wall-clock extraction deadline" do
    with_archive("chapter.mp3" => "audio") do |source|
      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source, max_duration: -1).extract!
      end
      assert_includes error.message, "time limit"
    end
  end

  test "rejects binary entry names that are not valid UTF-8 before creation" do
    with_archive("chapter.mp3" => "audio") do |source|
      error = assert_raises(DirectDownloadArchiveExtractor::Error) do
        build_extractor(source).send(:normalize_entry_name, "\xFFchapter.mp3".b, directory: false)
      end
      assert_includes error.message, "unsafe path"
    end
  end

  private

  def build_extractor(source, max_entries: 100, **options)
    DirectDownloadArchiveExtractor.new(
      source: source,
      destination: @destination,
      output_root: @root,
      max_bytes: 10.megabytes,
      max_entries: max_entries,
      **options
    )
  end

  def mutate_entry_fields(path)
    bytes = File.binread(path)
    end_record = bytes.rindex(ZipArchivePreflightService::END_OF_CENTRAL_DIRECTORY_SIGNATURE)
    central = bytes.byteslice(end_record + 16, 4).unpack1("V")
    local = bytes.byteslice(central + 42, 4).unpack1("V")
    yield bytes, central, local
    File.binwrite(path, bytes)
  end

  def with_archive(entries)
    Tempfile.create([ "direct-archive-", ".zip" ]) do |archive|
      archive.close
      Zip::File.open(archive.path, create: true) do |zipfile|
        entries.each do |name, content|
          if name.end_with?("/")
            zipfile.mkdir(name.delete_suffix("/"))
          else
            zipfile.get_output_stream(name) { |stream| stream.write(content) }
          end
        end
      end
      File.open(archive.path, "rb") { |source| yield source }
    end
  end
end
