# frozen_string_literal: true

require "digest"

# Validates the bounded ZIP end records and central directory before rubyzip is
# allowed to parse an untrusted archive. rubyzip materializes every central
# directory entry and trusts the EOCD entry count, so checking archive.entries
# after Zip::File.open is too late to prevent a metadata allocation bomb.
class ZipArchivePreflightService
  class Error < StandardError; end

  END_OF_CENTRAL_DIRECTORY_SIGNATURE = "PK\x05\x06".b
  CENTRAL_DIRECTORY_ENTRY_SIGNATURE = "PK\x01\x02".b
  LOCAL_FILE_HEADER_SIGNATURE = "PK\x03\x04".b
  ZIP64_LOCATOR_SIGNATURE = "PK\x06\x07".b
  ZIP64_END_SIGNATURE = "PK\x06\x06".b
  ZIP64_EXTRA_FIELD_ID = 0x0001

  END_OF_CENTRAL_DIRECTORY_BYTES = 22
  CENTRAL_DIRECTORY_ENTRY_BYTES = 46
  LOCAL_FILE_HEADER_BYTES = 30
  MAX_COMMENT_BYTES = 65_535
  ZIP64_LOCATOR_BYTES = 20
  ZIP64_END_BYTES = 56
  ZIP64_END_DECLARED_BYTES = 44

  # Shelfarr only extracts the two methods supported by rubyzip's built-in
  # decompressors. The allowed flag bits are deflate hints, a data descriptor,
  # and UTF-8 names; encryption and reserved/patching modes are rejected.
  SUPPORTED_COMPRESSION_METHODS = [ 0, 8 ].freeze
  SUPPORTED_GENERAL_PURPOSE_FLAGS = 0x0002 | 0x0004 | 0x0008 | 0x0800

  Result = Data.define(:entries, :central_directory_bytes)
  EndRecord = Data.define(
    :offset,
    :entries,
    :central_directory_bytes,
    :central_directory_offset
  )

  class << self
    def validate!(io, max_entries:, max_central_directory_bytes:)
      original_position = io.pos
      entry_limit = positive_limit(max_entries)
      central_directory_limit = positive_limit(max_central_directory_bytes)
      size = io.stat.size
      if size < END_OF_CENTRAL_DIRECTORY_BYTES
        raise Error, "ZIP archive is missing its central directory"
      end

      end_record = read_end_record(io, size)
      if end_record.entries > entry_limit
        raise Error, "ZIP archive contains too many entries"
      end
      if end_record.central_directory_bytes > central_directory_limit
        raise Error, "ZIP archive central directory is too large"
      end

      validate_central_directory!(
        io,
        end_record,
        max_entries: entry_limit
      )

      Result.new(
        entries: end_record.entries,
        central_directory_bytes: end_record.central_directory_bytes
      )
    rescue RangeError, TypeError, ArgumentError
      raise Error, "ZIP archive central directory is malformed"
    ensure
      io.seek(original_position, IO::SEEK_SET) if original_position
    end

    private

    def positive_limit(value)
      value = Integer(value)
      raise ArgumentError unless value.positive?

      value
    end

    def read_end_record(io, size)
      tail_size = [ size, END_OF_CENTRAL_DIRECTORY_BYTES + MAX_COMMENT_BYTES ].min
      tail_offset = size - tail_size
      tail = read_exact_at(io, tail_size, tail_offset)
      relative_offset, last_signature_offset = find_end_record(tail)

      # rubyzip uses the last raw EOCD signature, even when it occurs inside a
      # comment. A later complete-looking header could therefore bypass the
      # record we validated and drive a different allocation. A short literal
      # in a comment is harmless (rubyzip fails before reading any entries),
      # but a second complete header is ambiguous and must be rejected.
      if last_signature_offset > relative_offset &&
          last_signature_offset + END_OF_CENTRAL_DIRECTORY_BYTES <= tail.bytesize
        raise Error, "ZIP archive has an ambiguous end record"
      end

      absolute_offset = tail_offset + relative_offset
      record = tail.byteslice(relative_offset, END_OF_CENTRAL_DIRECTORY_BYTES)
      disk_number, central_disk, disk_entries, total_entries,
        central_bytes, central_offset, = record.byteslice(4, 18).unpack("vvvvVVv")

      zip64_required = [ disk_number, central_disk, disk_entries, total_entries ].include?(0xffff) ||
        [ central_bytes, central_offset ].include?(0xffff_ffff)

      if zip64_required
        values = zip64_values(io, absolute_offset)
        validate_standard_zip64_fields!(
          [ disk_number, central_disk, disk_entries, total_entries, central_bytes, central_offset ],
          values
        )
        disk_number, central_disk, disk_entries, total_entries,
          central_bytes, central_offset = values
      end

      if disk_number != 0 || central_disk != 0 || disk_entries != total_entries
        raise Error, "Multi-disk ZIP archives are not supported"
      end

      expected_end = zip64_required ? absolute_offset - ZIP64_LOCATOR_BYTES - ZIP64_END_BYTES : absolute_offset
      if central_offset.negative? || central_bytes.negative? ||
          central_offset + central_bytes != expected_end
        raise Error, "ZIP archive central directory is malformed"
      end

      EndRecord.new(
        offset: absolute_offset,
        entries: total_entries,
        central_directory_bytes: central_bytes,
        central_directory_offset: central_offset
      )
    end

    # Scan the bounded tail once and select the last signature whose declared
    # comment ends exactly at EOF. This permits a literal EOCD signature in a
    # valid ZIP comment without trusting the last arbitrary byte sequence.
    def find_end_record(tail)
      candidate = nil
      last_signature = nil
      search_offset = 0

      while (offset = tail.index(END_OF_CENTRAL_DIRECTORY_SIGNATURE, search_offset))
        last_signature = offset
        if offset + END_OF_CENTRAL_DIRECTORY_BYTES <= tail.bytesize
          comment_bytes = tail.byteslice(offset + 20, 2).unpack1("v")
          candidate = offset if offset + END_OF_CENTRAL_DIRECTORY_BYTES + comment_bytes == tail.bytesize
        end
        search_offset = offset + 1
      end

      raise Error, "ZIP archive is missing its central directory" unless candidate

      [ candidate, last_signature ]
    end

    def zip64_values(io, end_record_offset)
      locator_offset = end_record_offset - ZIP64_LOCATOR_BYTES
      zip64_offset = locator_offset - ZIP64_END_BYTES
      if zip64_offset.negative?
        raise Error, "ZIP64 archive is missing its locator"
      end

      locator = read_exact_at(io, ZIP64_LOCATOR_BYTES, locator_offset)
      unless locator.start_with?(ZIP64_LOCATOR_SIGNATURE)
        raise Error, "ZIP64 archive is missing its locator"
      end

      locator_disk, declared_zip64_offset, disk_count = locator.byteslice(4, 16).unpack("VQ<V")
      unless locator_disk.zero? && disk_count == 1
        raise Error, "Multi-disk ZIP archives are not supported"
      end
      unless declared_zip64_offset == zip64_offset
        raise Error, "ZIP64 central directory is malformed"
      end

      record = read_exact_at(io, ZIP64_END_BYTES, zip64_offset)
      unless record.start_with?(ZIP64_END_SIGNATURE)
        raise Error, "ZIP64 central directory is malformed"
      end

      declared_size = record.byteslice(4, 8).unpack1("Q<")
      unless declared_size == ZIP64_END_DECLARED_BYTES
        raise Error, "ZIP64 central directory is malformed"
      end

      _version_made, _version_needed, disk_number, central_disk,
        disk_entries, total_entries, central_bytes, central_offset =
        record.byteslice(12, ZIP64_END_DECLARED_BYTES).unpack("vvVVQ<Q<Q<Q<")
      [ disk_number, central_disk, disk_entries, total_entries, central_bytes, central_offset ]
    end

    def validate_standard_zip64_fields!(standard, zip64)
      standard.each_with_index do |value, index|
        sentinel = index < 4 ? 0xffff : 0xffff_ffff
        next if value == sentinel

        expected = zip64.fetch(index)
        expected = [ expected, sentinel ].min
        unless value == expected
          raise Error, "ZIP64 central directory is inconsistent"
        end
      end
    end

    def validate_central_directory!(io, end_record, max_entries:)
      cursor = end_record.central_directory_offset
      directory_end = cursor + end_record.central_directory_bytes
      entries = 0
      local_ranges = []
      name_digests = {}

      while cursor < directory_end
        raise Error, "ZIP archive contains too many entries" if entries >= max_entries

        header = read_exact_at(io, CENTRAL_DIRECTORY_ENTRY_BYTES, cursor)
        unless header.start_with?(CENTRAL_DIRECTORY_ENTRY_SIGNATURE)
          raise Error, "ZIP archive central directory is malformed"
        end

        general_purpose_flags = header.byteslice(8, 2).unpack1("v")
        compression_method = header.byteslice(10, 2).unpack1("v")
        crc = header.byteslice(16, 4).unpack1("V")
        compressed_size = header.byteslice(20, 4).unpack1("V")
        uncompressed_size = header.byteslice(24, 4).unpack1("V")
        name_bytes = header.byteslice(28, 2).unpack1("v")
        extra_bytes = header.byteslice(30, 2).unpack1("v")
        comment_bytes = header.byteslice(32, 2).unpack1("v")
        disk_start = header.byteslice(34, 2).unpack1("v")
        made_by_filesystem = header.getbyte(5)
        external_attributes = header.byteslice(38, 4).unpack1("V")
        local_offset = header.byteslice(42, 4).unpack1("V")

        validate_entry_features!(general_purpose_flags, compression_method, disk_start)
        validate_external_attributes!(made_by_filesystem, external_attributes)

        variable_offset = cursor + CENTRAL_DIRECTORY_ENTRY_BYTES
        entry_end = variable_offset + name_bytes + extra_bytes + comment_bytes
        if name_bytes.zero? || entry_end > directory_end
          raise Error, "ZIP archive central directory is malformed"
        end

        name = read_exact_at(io, name_bytes, variable_offset)
        if name.include?("\0") || name.include?("\\")
          raise Error, "ZIP archive contains an unsafe entry name"
        end
        name_digest = Digest::SHA256.digest(name)
        if name_digests.key?(name_digest)
          raise Error, "ZIP archive contains a duplicate entry name"
        end
        name_digests[name_digest] = true
        extra = read_exact_at(io, extra_bytes, variable_offset + name_bytes)
        zip64 = parse_extra_fields(extra)
        uncompressed_size, compressed_size, local_offset = resolve_zip64_entry_values(
          zip64,
          uncompressed_size,
          compressed_size,
          local_offset
        )

        local_ranges << validate_local_header!(
          io,
          local_offset: local_offset,
          central_directory_offset: end_record.central_directory_offset,
          central_name: name,
          central_flags: general_purpose_flags,
          central_compression_method: compression_method,
          central_crc: crc,
          central_compressed_size: compressed_size,
          central_uncompressed_size: uncompressed_size
        )

        entries += 1
        cursor = entry_end
      end

      if cursor != directory_end || entries != end_record.entries
        raise Error, "ZIP archive central directory entry count is inconsistent"
      end

      validate_nonoverlapping_local_ranges!(local_ranges)
    end

    def validate_entry_features!(flags, compression_method, disk_start)
      if (flags & ~SUPPORTED_GENERAL_PURPOSE_FLAGS).positive?
        raise Error, "ZIP archive uses unsupported or encrypted entry flags"
      end
      unless SUPPORTED_COMPRESSION_METHODS.include?(compression_method)
        raise Error, "ZIP archive uses an unsupported compression method"
      end
      raise Error, "Multi-disk ZIP archives are not supported" unless disk_start.zero?
    end

    def validate_external_attributes!(filesystem, attributes)
      return unless filesystem == 3 # Unix

      file_type = (attributes >> 16) & 0xf000
      return if file_type.in?([ 0, 0x4000, 0x8000 ])

      raise Error, "ZIP archive contains a symbolic link or special file"
    end

    def parse_extra_fields(extra)
      cursor = 0
      zip64 = nil

      while cursor < extra.bytesize
        if cursor + 4 > extra.bytesize
          raise Error, "ZIP archive contains a malformed extra field"
        end

        field_id, field_bytes = extra.byteslice(cursor, 4).unpack("vv")
        field_offset = cursor + 4
        field_end = field_offset + field_bytes
        if field_end > extra.bytesize
          raise Error, "ZIP archive contains a malformed extra field"
        end
        if field_id == ZIP64_EXTRA_FIELD_ID
          raise Error, "ZIP archive contains duplicate ZIP64 metadata" if zip64

          zip64 = extra.byteslice(field_offset, field_bytes)
        end
        cursor = field_end
      end

      zip64
    end

    def resolve_zip64_entry_values(zip64, uncompressed_size, compressed_size, local_offset)
      values = [ uncompressed_size, compressed_size, local_offset ]
      cursor = 0

      values.map! do |value|
        next value unless value == 0xffff_ffff
        unless zip64 && cursor + 8 <= zip64.bytesize
          raise Error, "ZIP archive contains incomplete ZIP64 entry metadata"
        end

        resolved = zip64.byteslice(cursor, 8).unpack1("Q<")
        cursor += 8
        resolved
      end
      values
    end

    def validate_local_header!(
      io,
      local_offset:,
      central_directory_offset:,
      central_name:,
      central_flags:,
      central_compression_method:,
      central_crc:,
      central_compressed_size:,
      central_uncompressed_size:
    )
      if local_offset.negative? || local_offset + LOCAL_FILE_HEADER_BYTES > central_directory_offset
        raise Error, "ZIP archive contains an invalid local header offset"
      end

      header = read_exact_at(io, LOCAL_FILE_HEADER_BYTES, local_offset)
      unless header.start_with?(LOCAL_FILE_HEADER_SIGNATURE)
        raise Error, "ZIP archive contains an invalid local header"
      end

      flags = header.byteslice(6, 2).unpack1("v")
      compression_method = header.byteslice(8, 2).unpack1("v")
      crc = header.byteslice(14, 4).unpack1("V")
      compressed_size = header.byteslice(18, 4).unpack1("V")
      uncompressed_size = header.byteslice(22, 4).unpack1("V")
      name_bytes = header.byteslice(26, 2).unpack1("v")
      extra_bytes = header.byteslice(28, 2).unpack1("v")
      validate_entry_features!(flags, compression_method, 0)

      unless flags == central_flags && compression_method == central_compression_method
        raise Error, "ZIP archive local and central headers disagree"
      end

      variable_offset = local_offset + LOCAL_FILE_HEADER_BYTES
      data_offset = variable_offset + name_bytes + extra_bytes
      if data_offset > central_directory_offset
        raise Error, "ZIP archive contains a truncated local header"
      end

      name = read_exact_at(io, name_bytes, variable_offset)
      unless name == central_name
        raise Error, "ZIP archive local and central filenames disagree"
      end

      local_extra = read_exact_at(io, extra_bytes, variable_offset + name_bytes)
      local_zip64 = parse_extra_fields(local_extra)
      local_uncompressed_size, local_compressed_size, = resolve_zip64_entry_values(
        local_zip64,
        uncompressed_size,
        compressed_size,
        0
      )

      data_descriptor = (flags & 0x0008).positive?
      if data_descriptor
        unless [ 0, central_crc ].include?(crc) &&
            [ 0, central_compressed_size ].include?(local_compressed_size) &&
            [ 0, central_uncompressed_size ].include?(local_uncompressed_size)
          raise Error, "ZIP archive local and central descriptor values disagree"
        end
      else
        unless local_compressed_size == central_compressed_size &&
            local_uncompressed_size == central_uncompressed_size && crc == central_crc
          raise Error, "ZIP archive local and central sizes disagree"
        end
      end

      data_end = data_offset + central_compressed_size
      if data_end > central_directory_offset
        raise Error, "ZIP archive compressed data overlaps its central directory"
      end

      # rubyzip's random-access entry reader uses the validated central values
      # and never parses the optional descriptor following compressed data.
      # Treat only the local header + compressed bytes as the occupied range:
      # descriptors may be signatureless and 32- or 64-bit, while a following
      # entry's independently validated local header cannot affect this read.
      [ local_offset, data_end ]
    end

    def validate_nonoverlapping_local_ranges!(ranges)
      previous_end = nil
      ranges.sort_by!(&:first)
      ranges.each do |start_offset, end_offset|
        if previous_end && start_offset < previous_end
          raise Error, "ZIP archive contains overlapping local entries"
        end

        previous_end = end_offset
      end
    end

    def read_exact_at(io, length, offset)
      return "".b if length.zero?

      value = io.pread(length, offset)
      unless value&.bytesize == length
        raise Error, "ZIP archive is truncated"
      end

      value
    rescue Errno::ESPIPE, NotImplementedError
      io.seek(offset, IO::SEEK_SET)
      value = io.read(length)
      unless value&.bytesize == length
        raise Error, "ZIP archive is truncated"
      end

      value
    end
  end
end
