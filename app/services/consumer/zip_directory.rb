# frozen_string_literal: true

# A bounded, strict reader for plain ZIP32 archives on an already-pinned
# descriptor. Comics (CBZ) and EPUB publications share it.
#
# Nothing is reopened by pathname. Only plain ZIP32 archives on one disk are
# accepted: the end-of-central-directory record must be unambiguous, the
# directory must end exactly where that record begins, and its size and entry
# count are bounded before any entry is parsed. Each entry's local header must
# repeat the directory's flags, method, name and (without a data descriptor)
# CRC and sizes, and entries must not overlap. Encryption, ZIP64, Unicode-path
# overrides, symlinks and special files, traversal and duplicate or ambiguous
# names reject the whole archive.
#
# Entry data is read only through #read_entry, which inflates within the
# directory's announced size and checks the CRC, or #stream_entry, which
# serves byte ranges of a stored (uncompressed) entry or inflates a deflated
# one up to the requested range without ever exceeding its announced size.
class Consumer::ZipDirectory
  class Invalid < StandardError; end

  MAX_ENTRIES = 10_000
  MAX_DIRECTORY_BYTES = 2.megabytes
  MAX_NAME_BYTES = 1024

  EOCD = "PK\x05\x06".b.freeze
  CENTRAL = 0x02014b50
  LOCAL = 0x04034b50
  ZIP64_LOCATOR = "PK\x06\x07".b.freeze
  EOCD_BYTES = 22
  CENTRAL_BYTES = 46
  LOCAL_BYTES = 30
  # Deflate options (bits 1-2), data descriptor (3) and UTF-8 names (11).
  # Encryption (0, 6), masked headers (13) and reserved bits are refused.
  ALLOWED_FLAGS = 0x080e
  DATA_DESCRIPTOR = 0x0008
  UTF8_NAMES = 0x0800
  # ZIP64 sizes, Info-ZIP Unicode path (an alternative name) and AES encryption.
  REFUSED_EXTRAS = [ 0x0001, 0x7075, 0x9901 ].freeze
  STORED = 0
  DEFLATED = 8
  CHUNK = 64.kilobytes

  Entry = Data.define(:name, :flags, :method, :crc, :compressed_size, :size, :offset, :directory, :data_offset)

  def initialize(file)
    @file = file
  end

  # Every validated entry, in directory order.
  def entries
    @entries ||= begin
      directory_offset, count, directory = central_directory
      check_local_records(parse_directory(directory, count), directory_offset)
    end
  rescue IOError, SystemCallError, EOFError, EncodingError, ArgumentError, RangeError
    raise Invalid, "This archive can't be read"
  end

  # The whole decoded entry, refused above `limit` decoded bytes or when its
  # CRC disagrees with the directory.
  def read_entry(entry, limit:)
    raise Invalid, "#{entry.name} is larger than #{limit} bytes" if entry.size > limit
    raise Invalid, "#{entry.name} is a folder" if entry.directory

    data = entry.method == STORED ? read(entry.size, entry.data_offset) : inflate_all(entry)
    raise Invalid, "#{entry.name} is damaged" unless data.bytesize == entry.size && Zlib.crc32(data) == entry.crc

    data
  rescue Zlib::Error
    raise Invalid, "#{entry.name} is damaged"
  end

  # Yields decoded bytes first..last (inclusive) of the entry in chunks. A
  # deflated entry is inflated from its start, never beyond its announced
  # size; the CRC is checked when the whole entry was produced.
  def stream_entry(entry, first, last)
    raise Invalid, "Invalid range" unless first >= 0 && last >= first && last < entry.size

    if entry.method == STORED
      position = first
      while position <= last
        length = [ CHUNK, last - position + 1 ].min
        yield read(length, entry.data_offset + position)
        position += length
      end
      return
    end

    produced = 0
    crc = 0
    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    remaining = entry.compressed_size
    cursor = entry.data_offset
    begin
      while remaining.positive? && produced <= last
        chunk = read([ CHUNK, remaining ].min, cursor)
        cursor += chunk.bytesize
        remaining -= chunk.bytesize
        # The block form yields output as it is produced, so a highly
        # compressed chunk is refused before it can grow past the entry.
        inflater.inflate(chunk) do |output|
          raise Invalid, "#{entry.name} decodes beyond its announced size" if produced + output.bytesize > entry.size

          crc = Zlib.crc32(output, crc)
          window_start = [ first - produced, 0 ].max
          window_end = [ last - produced, output.bytesize - 1 ].min
          yield output.byteslice(window_start, window_end - window_start + 1) if window_end >= window_start && produced <= last
          produced += output.bytesize
        end
      end
      raise Invalid, "#{entry.name} is truncated" if produced <= last
      raise Invalid, "#{entry.name} is damaged" if remaining.zero? && produced == entry.size && crc != entry.crc
    ensure
      inflater.close
    end
  rescue Zlib::Error
    raise Invalid, "#{entry.name} is damaged"
  end

  private

  def inflate_all(entry)
    output = +"".b
    stream_entry(entry, 0, entry.size - 1) { |chunk| output << chunk } if entry.size.positive?
    output
  end

  def read(length, offset)
    return "".b if length.zero?

    bytes = @file.pread(length, offset)
    raise Invalid, "This archive is truncated" unless bytes&.bytesize == length

    bytes
  end

  # The one end-of-central-directory record whose comment reaches end of file.
  # Two consistent candidates (a record hidden in another's comment) are
  # ambiguous: other ZIP readers may choose either.
  def central_directory
    size = @file.size
    raise Invalid, "This archive is too small" if size < EOCD_BYTES

    tail_length = [ size, EOCD_BYTES + 65_535 ].min
    tail_start = size - tail_length
    tail = read(tail_length, tail_start)
    candidates = []
    index = tail.bytesize - EOCD_BYTES
    while index >= 0 && (found = tail.rindex(EOCD, index))
      comment = tail.byteslice(found + 20, 2).unpack1("v")
      candidates << found if found + EOCD_BYTES + comment == tail.bytesize
      index = found - 1
    end
    raise Invalid, "This archive has no unambiguous ZIP directory" unless candidates.one?

    record = candidates.first
    _, disk, directory_disk, disk_entries, entries, directory_size, directory_offset = tail.byteslice(record, EOCD_BYTES).unpack("VvvvvVV")
    eocd_offset = tail_start + record
    unless disk.zero? && directory_disk.zero? && disk_entries == entries && entries.between?(1, MAX_ENTRIES) &&
        directory_size.between?(CENTRAL_BYTES * entries, MAX_DIRECTORY_BYTES) &&
        directory_offset + directory_size == eocd_offset
      raise Invalid, "This archive's directory is unsupported or too large"
    end
    raise Invalid, "ZIP64 archives are not supported" if eocd_offset >= 20 && read(4, eocd_offset - 20) == ZIP64_LOCATOR

    [ directory_offset, entries, read(directory_size, directory_offset) ]
  end

  def parse_directory(directory, count)
    entries = []
    names = Set.new
    cursor = 0
    count.times do
      raise Invalid, "This archive's directory is truncated" if cursor + CENTRAL_BYTES > directory.bytesize

      signature, made_by, needed, flags, method, _time, _date, crc, compressed, size, name_length, extra_length,
        comment_length, disk, _internal, external, offset = directory.byteslice(cursor, CENTRAL_BYTES).unpack("VvvvvvvVVVvvvvvVV")
      raise Invalid, "This archive's directory is damaged" unless signature == CENTRAL

      cursor += CENTRAL_BYTES
      raise Invalid, "This archive's directory is truncated" if cursor + name_length + extra_length + comment_length > directory.bytesize

      raw_name = directory.byteslice(cursor, name_length)
      extras = directory.byteslice(cursor + name_length, extra_length)
      cursor += name_length + extra_length + comment_length
      unless (flags & ~ALLOWED_FLAGS).zero? && [ STORED, DEFLATED ].include?(method) && (needed & 0xff) <= 45 && disk.zero? &&
          [ compressed, size, offset ].none?(0xffff_ffff) && (method == DEFLATED || compressed == size) && safe_extras?(extras)
        raise Invalid, "This archive uses unsupported ZIP features such as encryption or ZIP64"
      end
      raise Invalid, "This archive contains a link or special file" if special_file?(made_by, external)

      name = entry_name(raw_name, flags)
      directory_entry = name.end_with?("/")
      raise Invalid, "This archive contains a folder with data" if directory_entry && size.positive?
      raise Invalid, "This archive contains duplicate names" unless names.add?(name.unicode_normalize(:nfc))

      entries << Entry.new(name: name, flags: flags, method: method, crc: crc, compressed_size: compressed,
        size: size, offset: offset, directory: directory_entry, data_offset: nil)
    end
    raise Invalid, "This archive's directory has unexpected data" unless cursor == directory.bytesize

    entries
  end

  # Names are UTF-8 when flagged, otherwise ASCII only: legacy code pages are
  # ambiguous. No absolute, drive, backslash, control, empty, "." or ".." parts.
  def entry_name(raw, flags)
    raise Invalid, "This archive contains an unsupported name" unless raw.bytesize.between?(1, MAX_NAME_BYTES)
    raise Invalid, "This archive's names need UTF-8" unless (flags & UTF8_NAMES).positive? || raw.ascii_only?

    name = FilenameBytes.utf8(raw)
    parts = name.delete_suffix("/").split("/", -1)
    if name.match?(%r{[\\:\x00-\x1f\x7f]}) || name.start_with?("/") || parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }
      raise Invalid, "This archive contains an unsafe name"
    end

    name
  rescue EncodingError
    raise Invalid, "This archive contains a name that isn't valid UTF-8"
  end

  def safe_extras?(extras)
    cursor = 0
    while cursor < extras.bytesize
      return false if cursor + 4 > extras.bytesize

      id, length = extras.byteslice(cursor, 4).unpack("vv")
      return false if REFUSED_EXTRAS.include?(id) || cursor + 4 + length > extras.bytesize

      cursor += 4 + length
    end
    true
  end

  # Unix modes are in the high half of the external attributes. Only regular
  # files and folders are accepted; links and devices are refused.
  def special_file?(made_by, external)
    return false unless (made_by >> 8) == 3

    type = (external >> 16) & 0o170000
    !type.zero? && type != 0o100000 && type != 0o040000
  end

  # The local header in front of each entry must describe the same entry, and
  # entries must not share bytes.
  def check_local_records(entries, directory_offset)
    checked = entries.map do |entry|
      header = read(LOCAL_BYTES, entry.offset)
      signature, _needed, flags, method, _time, _date, crc, compressed, size, name_length, extra_length = header.unpack("VvvvvvVVVvv")
      descriptor = (entry.flags & DATA_DESCRIPTOR).positive?
      unless signature == LOCAL && flags == entry.flags && method == entry.method && name_length == entry.name.bytesize &&
          read(name_length, entry.offset + LOCAL_BYTES) == entry.name.b &&
          safe_extras?(read(extra_length, entry.offset + LOCAL_BYTES + name_length)) &&
          (descriptor ? [ crc, compressed, size ].all? { |value| value.zero? } || [ crc, compressed, size ] == [ entry.crc, entry.compressed_size, entry.size ] : [ crc, compressed, size ] == [ entry.crc, entry.compressed_size, entry.size ])
        raise Invalid, "This archive's entry headers disagree with its directory"
      end
      data_offset = entry.offset + LOCAL_BYTES + name_length + extra_length
      finish = data_offset + entry.compressed_size + (descriptor ? 12 : 0)
      raise Invalid, "This archive's entries extend into its directory" if finish > directory_offset

      entry.with(data_offset: data_offset)
    end
    checked.map { |entry| [ entry.offset, entry.data_offset + entry.compressed_size + ((entry.flags & DATA_DESCRIPTOR).positive? ? 12 : 0) ] }
      .sort.each_cons(2) do |(_, finish), (start, _)|
        raise Invalid, "This archive's entries overlap" if start < finish
      end
    checked
  end
end
