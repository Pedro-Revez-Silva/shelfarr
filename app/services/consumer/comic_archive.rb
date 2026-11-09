# frozen_string_literal: true

# The authoritative page order of a CBZ (a ZIP of JPEG, PNG or WebP pages),
# read from bounded ZIP metadata on an already-pinned descriptor.
#
# Nothing is inflated, extracted or reopened by pathname. Only plain ZIP32
# archives on one disk are accepted: the end-of-central-directory record must
# be unambiguous, the directory must end exactly where that record begins, and
# its size and entry count are bounded before any entry is parsed. Each entry's
# local header must repeat the directory's flags, method, name and (without a
# data descriptor) CRC and sizes, and entries must not overlap. Encryption,
# ZIP64, Unicode-path overrides, symlinks and special files, traversal and
# duplicate or ambiguous names reject the whole archive.
#
# This proves the archive's structure, not that every image decodes: clients
# still inflate within the announced size, check the CRC and bound decoded
# dimensions.
class Consumer::ComicArchive
  class Invalid < StandardError; end

  MAX_ENTRIES = 10_000
  MAX_DIRECTORY_BYTES = 2.megabytes
  MAX_METADATA_BYTES = 8.megabytes
  MAX_IMAGE_BYTES = 32.megabytes
  MAX_COMPRESSED_IMAGE_BYTES = MAX_IMAGE_BYTES + 64.kilobytes
  MAX_TOTAL_BYTES = 2.gigabytes
  MAX_NAME_BYTES = 1024
  IMAGE_TYPES = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png", "webp" => "image/webp" }.freeze

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
  # Per-page response overhead besides the escaped name, for the metadata bound.
  ITEM_OVERHEAD = 220

  Entry = Data.define(:name, :flags, :method, :crc, :compressed_size, :size, :offset, :directory)

  def self.pages(file)
    new(file).pages
  end

  def initialize(file)
    @file = file
  end

  def pages
    directory_offset, count, directory = central_directory
    entries = parse_directory(directory, count)
    check_local_records(entries, directory_offset)
    pages = []
    total = 0
    metadata = 0
    entries.each do |entry|
      next if entry.directory || hidden?(entry.name)

      type = IMAGE_TYPES[File.extname(entry.name).delete_prefix(".").downcase]
      next unless type
      raise Invalid, "A comic page exceeds 32 MiB" unless entry.size.between?(1, MAX_IMAGE_BYTES)
      unless entry.compressed_size.between?(1, MAX_COMPRESSED_IMAGE_BYTES)
        raise Invalid, "A comic page exceeds the safe compressed download limit"
      end

      total += entry.size
      raise Invalid, "Comic pages exceed 2 GiB" if total > MAX_TOTAL_BYTES

      href = escape(entry.name)
      metadata += href.bytesize + ITEM_OVERHEAD
      raise Invalid, "This comic's page list is too large" if metadata > MAX_METADATA_BYTES

      pages << { entry: entry, href: href, media_type: type }
    end
    raise Invalid, "This comic contains no supported image pages" if pages.empty?

    pages.sort_by { |page| natural_key(page[:entry].name) }.each_with_index.map do |page, index|
      entry = page[:entry]
      { position: index + 1, href: page[:href], media_type: page[:media_type], size_bytes: entry.size,
        compressed_size: entry.compressed_size, compression_method: entry.method,
        local_header_offset: entry.offset, crc32: format("%08x", entry.crc) }
    end
  rescue IOError, SystemCallError, EOFError, EncodingError, ArgumentError, RangeError
    raise Invalid, "This comic archive can't be read"
  end

  private

  def read(length, offset)
    return "".b if length.zero?

    bytes = @file.pread(length, offset)
    raise Invalid, "This comic archive is truncated" unless bytes&.bytesize == length

    bytes
  end

  # The one end-of-central-directory record whose comment reaches end of file.
  # Two consistent candidates (a record hidden in another's comment) are
  # ambiguous: other ZIP readers may choose either.
  def central_directory
    size = @file.size
    raise Invalid, "This comic archive is too small" if size < EOCD_BYTES

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
    raise Invalid, "This comic archive has no unambiguous ZIP directory" unless candidates.one?

    record = candidates.first
    _, disk, directory_disk, disk_entries, entries, directory_size, directory_offset = tail.byteslice(record, EOCD_BYTES).unpack("VvvvvVV")
    eocd_offset = tail_start + record
    unless disk.zero? && directory_disk.zero? && disk_entries == entries && entries.between?(1, MAX_ENTRIES) &&
        directory_size.between?(CENTRAL_BYTES * entries, MAX_DIRECTORY_BYTES) &&
        directory_offset + directory_size == eocd_offset
      raise Invalid, "This comic archive's directory is unsupported or too large"
    end
    raise Invalid, "ZIP64 comic archives are not supported" if eocd_offset >= 20 && read(4, eocd_offset - 20) == ZIP64_LOCATOR

    [ directory_offset, entries, read(directory_size, directory_offset) ]
  end

  def parse_directory(directory, count)
    entries = []
    names = Set.new
    cursor = 0
    count.times do
      raise Invalid, "This comic archive's directory is truncated" if cursor + CENTRAL_BYTES > directory.bytesize

      signature, made_by, needed, flags, method, _time, _date, crc, compressed, size, name_length, extra_length,
        comment_length, disk, _internal, external, offset = directory.byteslice(cursor, CENTRAL_BYTES).unpack("VvvvvvvVVVvvvvvVV")
      raise Invalid, "This comic archive's directory is damaged" unless signature == CENTRAL

      cursor += CENTRAL_BYTES
      raise Invalid, "This comic archive's directory is truncated" if cursor + name_length + extra_length + comment_length > directory.bytesize

      raw_name = directory.byteslice(cursor, name_length)
      extras = directory.byteslice(cursor + name_length, extra_length)
      cursor += name_length + extra_length + comment_length
      unless (flags & ~ALLOWED_FLAGS).zero? && [ 0, 8 ].include?(method) && (needed & 0xff) <= 45 && disk.zero? &&
          [ compressed, size, offset ].none?(0xffff_ffff) && (method == 8 || compressed == size) && safe_extras?(extras)
        raise Invalid, "This comic uses unsupported ZIP features such as encryption or ZIP64"
      end
      raise Invalid, "This comic contains a link or special file" if special_file?(made_by, external)

      name = entry_name(raw_name, flags)
      directory_entry = name.end_with?("/")
      raise Invalid, "This comic contains a folder with data" if directory_entry && size.positive?
      raise Invalid, "This comic contains duplicate page names" unless names.add?(name.unicode_normalize(:nfc))

      entries << Entry.new(name: name, flags: flags, method: method, crc: crc, compressed_size: compressed,
        size: size, offset: offset, directory: directory_entry)
    end
    raise Invalid, "This comic archive's directory has unexpected data" unless cursor == directory.bytesize

    entries
  end

  # Names are UTF-8 when flagged, otherwise ASCII only: legacy code pages are
  # ambiguous. No absolute, drive, backslash, control, empty, "." or ".." parts.
  def entry_name(raw, flags)
    raise Invalid, "This comic contains an unsupported page name" unless raw.bytesize.between?(1, MAX_NAME_BYTES)
    raise Invalid, "This comic's page names need UTF-8" unless (flags & UTF8_NAMES).positive? || raw.ascii_only?

    name = FilenameBytes.utf8(raw)
    parts = name.delete_suffix("/").split("/", -1)
    if name.match?(%r{[\\:\x00-\x1f\x7f]}) || name.start_with?("/") || parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }
      raise Invalid, "This comic contains an unsafe page name"
    end

    name
  rescue EncodingError
    raise Invalid, "This comic contains a page name that isn't valid UTF-8"
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
  # files and folders are pages or containers; links and devices are refused.
  def special_file?(made_by, external)
    return false unless (made_by >> 8) == 3

    type = (external >> 16) & 0o170000
    !type.zero? && type != 0o100000 && type != 0o040000
  end

  # The local header in front of each entry must describe the same entry, and
  # entries must not share bytes.
  def check_local_records(entries, directory_offset)
    ranges = entries.map do |entry|
      header = read(LOCAL_BYTES, entry.offset)
      signature, _needed, flags, method, _time, _date, crc, compressed, size, name_length, extra_length = header.unpack("VvvvvvVVVvv")
      descriptor = (entry.flags & DATA_DESCRIPTOR).positive?
      unless signature == LOCAL && flags == entry.flags && method == entry.method && name_length == entry.name.bytesize &&
          read(name_length, entry.offset + LOCAL_BYTES) == entry.name.b &&
          safe_extras?(read(extra_length, entry.offset + LOCAL_BYTES + name_length)) &&
          (descriptor ? [ crc, compressed, size ].all? { |value| value.zero? } || [ crc, compressed, size ] == [ entry.crc, entry.compressed_size, entry.size ] : [ crc, compressed, size ] == [ entry.crc, entry.compressed_size, entry.size ])
        raise Invalid, "This comic's page headers disagree with its directory"
      end
      finish = entry.offset + LOCAL_BYTES + name_length + extra_length + entry.compressed_size + (descriptor ? 12 : 0)
      raise Invalid, "This comic's pages extend into its directory" if finish > directory_offset

      [ entry.offset, finish ]
    end
    ranges.sort.each_cons(2) do |(_, finish), (start, _)|
      raise Invalid, "This comic's pages overlap" if start < finish
    end
  end

  # Operating-system metadata (such as macOS "._" resource forks) is not a page.
  def hidden?(name)
    name.split("/").any? { |part| part.start_with?(".") || part == "__MACOSX" }
  end

  def escape(name)
    FilenameBytes.utf8(name.b.gsub(%r{[^A-Za-z0-9\-._~/]}n) { |byte| format("%%%02X", byte.ord) })
  end

  # Natural order (page2 before page10), case-insensitive, with the exact
  # name breaking ties so the order is deterministic.
  def natural_key(name)
    [ name.downcase.split(/(\d+)/).each_with_index.map { |part, index| index.odd? ? part.to_i : part }, name.b ]
  end
end
