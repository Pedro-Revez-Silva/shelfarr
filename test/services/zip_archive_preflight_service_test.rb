# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "zip"

class ZipArchivePreflightServiceTest < ActiveSupport::TestCase
  DEFAULT_MAX_ENTRIES = 100
  DEFAULT_MAX_CENTRAL_BYTES = 1.megabyte

  test "accepts a bounded ordinary archive and restores the descriptor position" do
    with_zip("first.txt" => "one", "folder/second.txt" => "two") do |path|
      File.open(path, "rb") do |file|
        file.seek(3)
        result = validate(file)

        assert_equal 2, result.entries
        assert_operator result.central_directory_bytes, :>, 0
        assert_operator result.compressed_bytes, :>, 0
        assert_equal 6, result.uncompressed_bytes
        assert_equal 3, file.pos
      end
    end
  end

  test "finds the real EOCD when a short literal signature occurs in its comment" do
    with_zip("book.epub" => "content") do |path|
      bytes = File.binread(path)
      comment = "literal-signature-PK\x05\x06".b
      eocd = eocd_offset(bytes)
      bytes[eocd + 20, 2] = [ comment.bytesize ].pack("v")
      bytes << comment
      File.binwrite(path, bytes)

      File.open(path, "rb") do |file|
        assert_equal 1, validate(file).entries
      end
    end
  end

  test "rejects a later complete EOCD-shaped sequence in a comment" do
    with_zip("book.epub" => "content") do |path|
      bytes = File.binread(path)
      comment = "PK\x05\x06".b + ("\0" * 18) + "tail"
      eocd = eocd_offset(bytes)
      bytes[eocd + 20, 2] = [ comment.bytesize ].pack("v")
      bytes << comment
      File.binwrite(path, bytes)

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "ambiguous"
      end
    end
  end

  test "rejects an EOCD count that understates the actual central headers" do
    with_zip("first.txt" => "one", "second.txt" => "two") do |path|
      mutate_bytes(path) do |bytes|
        eocd = eocd_offset(bytes)
        bytes[eocd + 8, 4] = [ 1, 1 ].pack("vv")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "entry count"
      end
    end
  end

  test "rejects a central directory larger than the configured byte cap" do
    with_zip("first.txt" => "one") do |path|
      File.open(path, "rb") do |file|
        central_bytes = eocd_fields(File.binread(path)).fetch(:central_bytes)
        error = assert_raises(ZipArchivePreflightService::Error) do
          validate(file, max_central_directory_bytes: central_bytes - 1)
        end
        assert_includes error.message, "too large"
      end
    end
  end

  test "rejects declared extracted bytes above the configured cap" do
    with_zip("first.txt" => "12345", "second.txt" => "67890") do |path|
      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) do
          validate(file, max_uncompressed_bytes: 9)
        end
        assert_includes error.message, "declared extracted size"
      end
    end
  end

  test "rejects entries above the configured compression ratio" do
    with_zip("bomb.txt" => ("0" * 1.megabyte)) do |path|
      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) do
          validate(file, max_compression_ratio: 10)
        end
        assert_includes error.message, "compression ratio"
      end
    end
  end

  test "rejects a central entry whose variable metadata escapes the bounded directory" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        bytes[central + 28, 2] = [ 0xffff ].pack("v")
      end

      File.open(path, "rb") do |file|
        assert_raises(ZipArchivePreflightService::Error) { validate(file) }
      end
    end
  end

  test "rejects encrypted entry flags before rubyzip sees the archive" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        fields = eocd_fields(bytes)
        central = fields.fetch(:central_offset)
        local = bytes.byteslice(central + 42, 4).unpack1("V")
        bytes[central + 8, 2] = [ bytes.byteslice(central + 8, 2).unpack1("v") | 1 ].pack("v")
        bytes[local + 6, 2] = [ bytes.byteslice(local + 6, 2).unpack1("v") | 1 ].pack("v")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "encrypted"
      end
    end
  end

  test "rejects unsupported compression methods before rubyzip sees the archive" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        local = bytes.byteslice(central + 42, 4).unpack1("V")
        bytes[central + 10, 2] = [ 99 ].pack("v")
        bytes[local + 8, 2] = [ 99 ].pack("v")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "compression"
      end
    end
  end

  test "rejects Unix symbolic-link metadata before rubyzip sees the archive" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        bytes.setbyte(central + 5, 3)
        attributes = (0xa000 | 0o777) << 16
        bytes[central + 38, 4] = [ attributes ].pack("V")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "symbolic link or special file"
      end
    end
  end

  test "rejects local and central filename disagreement" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        local = bytes.byteslice(central + 42, 4).unpack1("V")
        bytes.setbyte(local + ZipArchivePreflightService::LOCAL_FILE_HEADER_BYTES, "X".ord)
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "filenames disagree"
      end
    end
  end

  test "rejects duplicate central names before rubyzip collapses them" do
    with_zip("first.txt" => "one", "other.txt" => "two") do |path|
      mutate_bytes(path) do |bytes|
        fields = eocd_fields(bytes)
        first = fields.fetch(:central_offset)
        first_name_bytes = bytes.byteslice(first + 28, 2).unpack1("v")
        first_extra_bytes = bytes.byteslice(first + 30, 2).unpack1("v")
        first_comment_bytes = bytes.byteslice(first + 32, 2).unpack1("v")
        second = first + ZipArchivePreflightService::CENTRAL_DIRECTORY_ENTRY_BYTES +
          first_name_bytes + first_extra_bytes + first_comment_bytes
        second_local = bytes.byteslice(second + 42, 4).unpack1("V")
        first_name = bytes.byteslice(first + ZipArchivePreflightService::CENTRAL_DIRECTORY_ENTRY_BYTES,
          first_name_bytes)
        bytes[second + ZipArchivePreflightService::CENTRAL_DIRECTORY_ENTRY_BYTES, first_name_bytes] = first_name
        bytes[second_local + ZipArchivePreflightService::LOCAL_FILE_HEADER_BYTES, first_name_bytes] = first_name
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "duplicate entry name"
      end
    end
  end

  test "accepts zero local values for a data-descriptor entry" do
    with_zip("first.txt" => "one") do |path|
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        local = bytes.byteslice(central + 42, 4).unpack1("V")
        flags = bytes.byteslice(central + 8, 2).unpack1("v") | 0x0008
        bytes[central + 8, 2] = [ flags ].pack("v")
        bytes[local + 6, 2] = [ flags ].pack("v")
        bytes[local + 14, 12] = [ 0, 0, 0 ].pack("VVV")
      end

      File.open(path, "rb") do |file|
        assert_equal 1, validate(file).entries
      end
    end
  end

  test "rejects a nonzero local data-descriptor size that disagrees with central metadata" do
    with_zip("first.txt" => "one") do |path|
      resolved_compressed_size = Zip::File.open(path) { |archive| archive.first.compressed_size }
      mutate_bytes(path) do |bytes|
        central = eocd_fields(bytes).fetch(:central_offset)
        local = bytes.byteslice(central + 42, 4).unpack1("V")
        flags = bytes.byteslice(central + 8, 2).unpack1("v") | 0x0008
        bytes[central + 8, 2] = [ flags ].pack("v")
        bytes[local + 6, 2] = [ flags ].pack("v")
        bytes[local + 18, 4] = [ resolved_compressed_size + 1 ].pack("V")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "descriptor values disagree"
      end
    end
  end

  test "accepts a canonical ZIP64 end record without reading an extensible allocation" do
    with_zip("first.txt" => "one") do |path|
      make_zip64!(path)

      File.open(path, "rb") do |file|
        assert_equal 1, validate(file).entries
      end
    end
  end

  test "rejects a ZIP64 end record with a large declared extensible sector" do
    with_zip("first.txt" => "one") do |path|
      zip64_offset = make_zip64!(path)
      mutate_bytes(path) do |bytes|
        bytes[zip64_offset + 4, 8] = [ 1.gigabyte ].pack("Q<")
      end

      File.open(path, "rb") do |file|
        error = assert_raises(ZipArchivePreflightService::Error) { validate(file) }
        assert_includes error.message, "ZIP64 central directory is malformed"
      end
    end
  end

  test "rejects a ZIP64 locator that points away from its bounded end record" do
    with_zip("first.txt" => "one") do |path|
      zip64_offset = make_zip64!(path)
      mutate_bytes(path) do |bytes|
        locator_offset = zip64_offset + ZipArchivePreflightService::ZIP64_END_BYTES
        bytes[locator_offset + 8, 8] = [ zip64_offset + 1 ].pack("Q<")
      end

      File.open(path, "rb") do |file|
        assert_raises(ZipArchivePreflightService::Error) { validate(file) }
      end
    end
  end

  test "bounds every individual descriptor read while scanning central metadata" do
    with_zip("first.txt" => "one", "second.txt" => "two") do |path|
      File.open(path, "rb") do |file|
        guarded = ReadGuard.new(file)
        assert_equal 2, validate(guarded).entries
        assert_operator guarded.maximum_read, :<=,
          ZipArchivePreflightService::END_OF_CENTRAL_DIRECTORY_BYTES +
            ZipArchivePreflightService::MAX_COMMENT_BYTES
      end
    end
  end

  private

  ReadGuard = Struct.new(:io, :maximum_read) do
    def initialize(io)
      super(io, 0)
    end

    def pos
      io.pos
    end

    def stat
      io.stat
    end

    def pread(length, offset)
      self.maximum_read = [ maximum_read, length ].max
      io.pread(length, offset)
    end

    def seek(...)
      io.seek(...)
    end
  end

  def validate(
    file,
    max_entries: DEFAULT_MAX_ENTRIES,
    max_central_directory_bytes: DEFAULT_MAX_CENTRAL_BYTES,
    max_uncompressed_bytes: nil,
    max_compression_ratio: nil
  )
    ZipArchivePreflightService.validate!(
      file,
      max_entries: max_entries,
      max_central_directory_bytes: max_central_directory_bytes,
      max_uncompressed_bytes: max_uncompressed_bytes,
      max_compression_ratio: max_compression_ratio
    )
  end

  def with_zip(entries)
    Tempfile.create([ "archive-preflight-", ".zip" ]) do |archive|
      path = archive.path
      archive.close
      Zip::File.open(path, create: true) do |zipfile|
        entries.each do |name, content|
          zipfile.get_output_stream(name) { |stream| stream.write(content) }
        end
      end
      yield path
    end
  end

  def mutate_bytes(path)
    bytes = File.binread(path)
    yield bytes
    File.binwrite(path, bytes)
  end

  def eocd_offset(bytes)
    bytes.rindex(ZipArchivePreflightService::END_OF_CENTRAL_DIRECTORY_SIGNATURE) ||
      raise("EOCD not found")
  end

  def eocd_fields(bytes)
    offset = eocd_offset(bytes)
    disk, central_disk, disk_entries, entries, central_bytes, central_offset, comment_bytes =
      bytes.byteslice(offset + 4, 18).unpack("vvvvVVv")
    {
      offset: offset,
      disk: disk,
      central_disk: central_disk,
      disk_entries: disk_entries,
      entries: entries,
      central_bytes: central_bytes,
      central_offset: central_offset,
      comment_bytes: comment_bytes
    }
  end

  def make_zip64!(path)
    bytes = File.binread(path)
    fields = eocd_fields(bytes)
    eocd = fields.fetch(:offset)
    zip64 = [
      ZipArchivePreflightService::ZIP64_END_SIGNATURE,
      ZipArchivePreflightService::ZIP64_END_DECLARED_BYTES,
      45,
      45,
      0,
      0,
      fields.fetch(:entries),
      fields.fetch(:entries),
      fields.fetch(:central_bytes),
      fields.fetch(:central_offset)
    ].pack("a4Q<vvVVQ<Q<Q<Q<")
    locator = [
      ZipArchivePreflightService::ZIP64_LOCATOR_SIGNATURE,
      0,
      eocd,
      1
    ].pack("a4VQ<V")
    ordinary_end = bytes.byteslice(eocd..)
    ordinary_end[8, 4] = [ 0xffff, 0xffff ].pack("vv")
    ordinary_end[12, 8] = [ 0xffff_ffff, 0xffff_ffff ].pack("VV")
    File.binwrite(path, bytes.byteslice(0, eocd) + zip64 + locator + ordinary_end)
    eocd
  end
end
