# frozen_string_literal: true

# The authoritative page order of a CBZ (a ZIP of JPEG, PNG or WebP pages),
# read from bounded ZIP metadata on an already-pinned descriptor.
#
# Nothing is inflated, extracted or reopened by pathname. The archive structure
# is checked by Consumer::ZipDirectory: plain ZIP32 on one disk, an
# unambiguous bounded directory, local headers that repeat it, no overlapping
# entries, and no encryption, ZIP64, Unicode-path overrides, links, special
# files, traversal or duplicate names.
#
# This proves the archive's structure, not that every image decodes: clients
# still inflate within the announced size, check the CRC and bound decoded
# dimensions.
class Consumer::ComicArchive < Consumer::ZipDirectory
  MAX_METADATA_BYTES = 8.megabytes
  MAX_IMAGE_BYTES = 32.megabytes
  MAX_COMPRESSED_IMAGE_BYTES = MAX_IMAGE_BYTES + 64.kilobytes
  MAX_TOTAL_BYTES = 2.gigabytes
  IMAGE_TYPES = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png", "webp" => "image/webp" }.freeze
  # Per-page response overhead besides the escaped name, for the metadata bound.
  ITEM_OVERHEAD = 220

  def self.pages(file)
    new(file).pages
  end

  def pages
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
