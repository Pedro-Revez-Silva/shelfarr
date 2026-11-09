# frozen_string_literal: true

require "zlib"

# A bounded view of one EPUB generation on an already-pinned descriptor: its
# container, package document (OPF), manifest and spine, and the bytes of the
# manifest's own resources.
#
# The archive structure is checked by Consumer::ZipDirectory. XML is parsed
# without network access, DTD loading or entity substitution, and documents
# that declare entities are refused outright. Every path is resolved inside
# the archive: absolute URLs, remote resources, "..", and anything that is
# not a manifest item (or the container and package documents themselves)
# cannot be read through this class.
class Consumer::EpubPackage
  class Invalid < StandardError; end

  CONTAINER = "META-INF/container.xml"
  MAX_XML_BYTES = 4.megabytes
  MAX_TEXT_BYTES = 16.megabytes
  # Non-audio resources a reader loads into memory (text, styles, images, fonts).
  MAX_RESOURCE_BYTES = 32.megabytes
  MAX_AUDIO_BYTES = 2.gigabytes
  MAX_ITEMS = 5_000
  MAX_HREF_BYTES = 2048
  AUDIO_TYPES = %w[audio/mpeg audio/mp4 audio/ogg audio/opus audio/aac audio/wav audio/x-wav audio/wave audio/flac].freeze
  TEXT_TYPES = %w[application/xhtml+xml text/html].freeze
  SMIL_TYPE = "application/smil+xml"
  # Scripted content is never served, even to a reader that sandboxes it.
  REFUSED_TYPES = %w[application/javascript text/javascript application/ecmascript text/ecmascript].freeze
  OPF_NS = "http://www.idpf.org/2007/opf"
  CONTAINER_NS = "urn:oasis:names:tc:opendocument:xmlns:container"

  Item = Data.define(:id, :path, :media_type, :properties, :media_overlay, :size)
  SpineItem = Data.define(:idref, :linear)

  attr_reader :package_path, :items, :spine

  def self.open(file)
    new(file).tap(&:load)
  end

  def initialize(file)
    @zip = Consumer::ZipDirectory.new(file)
  end

  def load
    @entries = @zip.entries.reject(&:directory).index_by(&:name)
    @package_path = read_container
    package = xml(@package_path, limit: MAX_XML_BYTES)
    root = package.root
    raise Invalid, "The package document isn't an EPUB package" unless root&.name == "package" && root.namespace&.href == OPF_NS

    @items = {}
    by_path = {}
    root.xpath("opf:manifest/opf:item", "opf" => OPF_NS).each do |node|
      raise Invalid, "This book lists too many resources" if @items.size >= MAX_ITEMS

      id = node["id"].to_s
      href = node["href"].to_s
      media_type = node["media-type"].to_s.split(";").first.to_s.strip.downcase
      raise Invalid, "A manifest item is incomplete" if id.empty? || href.empty? || media_type.empty? || @items.key?(id)

      path = resolve(href, from: @package_path)
      # Remote resources are not part of this generation and are never fetched.
      next if path.nil?

      entry = @entries[path]
      raise Invalid, "Two manifest items name the same resource" if by_path.key?(path)

      item = Item.new(id: id, path: path, media_type: media_type, properties: node["properties"].to_s.split,
        media_overlay: node["media-overlay"].presence, size: entry&.size)
      @items[id] = item
      by_path[path] = item
    end
    @by_path = by_path
    @spine = root.xpath("opf:spine/opf:itemref", "opf" => OPF_NS).map do |node|
      SpineItem.new(idref: node["idref"].to_s, linear: node["linear"].to_s != "no")
    end
    raise Invalid, "This book has no reading order" if @spine.empty?

    self
  rescue Consumer::ZipDirectory::Invalid => error
    raise Invalid, error.message
  end

  def item_at(path)
    @by_path[path]
  end

  def entry(path)
    @entries[path]
  end

  # Text documents in reading order, each once.
  def spine_items
    @spine.filter_map { |ref| @items[ref.idref] }.select { |item| TEXT_TYPES.include?(item.media_type) }.uniq(&:path)
  end

  def linear_spine_items
    linear = @spine.select(&:linear).map(&:idref)
    spine_items.select { |item| linear.include?(item.id) }
  end

  # Whether this path may be served to a reader: the container, the package
  # document, or a present manifest item that isn't script.
  def servable?(path)
    return true if path == CONTAINER || path == @package_path

    item = @by_path[path]
    item && @entries[path] && !REFUSED_TYPES.include?(item.media_type)
  end

  def media_type_of(path)
    return "application/xml" if path == CONTAINER
    return "application/oebps-package+xml" if path == @package_path

    @by_path[path]&.media_type
  end

  def size_limit(path)
    AUDIO_TYPES.include?(media_type_of(path)) ? MAX_AUDIO_BYTES : MAX_RESOURCE_BYTES
  end

  def read(path, limit:)
    entry = @entries[path]
    raise Invalid, "#{path} is missing from this book" unless entry

    @zip.read_entry(entry, limit: limit)
  rescue Consumer::ZipDirectory::Invalid => error
    raise Invalid, error.message
  end

  def stream(path, first, last, &block)
    @zip.stream_entry(@entries.fetch(path), first, last, &block)
  rescue Consumer::ZipDirectory::Invalid, KeyError => error
    raise Invalid, error.message
  end

  # Strict, network-free XML. Entity declarations (internal or external)
  # are refused before parsing; DTDs are neither loaded nor validated.
  def xml(path, limit:, strict: true)
    self.class.parse_xml(read(path, limit: limit), strict: strict)
  end

  # UTF-16 and UTF-32 documents (which contain NUL bytes) are refused so the
  # entity check above cannot be bypassed by an interleaved encoding.
  def self.parse_xml(bytes, strict: true)
    raw = bytes.b
    raise Invalid, "This book's XML isn't UTF-8" if raw.include?("\x00".b)
    raise Invalid, "This book's XML declares entities, which aren't supported" if raw.include?("<!ENTITY".b)

    options = Nokogiri::XML::ParseOptions::NONET
    options |= strict ? Nokogiri::XML::ParseOptions::STRICT : Nokogiri::XML::ParseOptions::RECOVER
    Nokogiri::XML(raw, nil, nil, options)
  rescue Nokogiri::XML::SyntaxError
    raise Invalid, "This book contains XML that isn't well formed"
  end

  # A relative IRI reference from one archive document to another, as an
  # archive path (and fragment). nil for absolute or remote references;
  # Invalid for references that leave the archive or are malformed.
  def resolve(reference, from:, fragment: false)
    raise Invalid, "A reference is too long" if reference.bytesize > MAX_HREF_BYTES

    href, separator, anchor = reference.partition("#")
    return nil if href.match?(/\A[a-z][a-z0-9+.\-]*:/i) || href.start_with?("//")
    raise Invalid, "A reference has a query" if href.include?("?")
    raise Invalid, "A reference is absolute" if href.start_with?("/")

    decoded = FilenameBytes.utf8(URI::DEFAULT_PARSER.unescape(href))
    raise Invalid, "A reference contains control characters" if decoded.match?(/[\x00-\x1f\x7f\\]/)

    parts = File.dirname(from).split("/").reject { |part| part == "." || part.empty? }
    decoded.split("/", -1).each do |part|
      next if part == "." || part.empty?
      raise Invalid, "A reference leaves the book" if part == ".." && parts.empty?

      part == ".." ? parts.pop : parts.push(part)
    end
    path = parts.join("/")
    path = from if href.empty?
    return path unless fragment

    [ path, separator.empty? ? nil : FilenameBytes.utf8(URI::DEFAULT_PARSER.unescape(anchor)) ]
  rescue EncodingError, ArgumentError
    raise Invalid, "A reference isn't valid UTF-8"
  end

  private

  def read_container
    document = xml(CONTAINER, limit: MAX_XML_BYTES)
    paths = document.xpath("//c:rootfile[@media-type='application/oebps-package+xml']/@full-path", "c" => CONTAINER_NS).map(&:value)
    raise Invalid, "This book has no package document" if paths.empty?

    path = paths.first
    raise Invalid, "The package document path is unsafe" if path.start_with?("/") || path.split("/").include?("..") || path.match?(/[\x00-\x1f\\]/)
    raise Invalid, "The package document is missing" unless @entries.key?(path)

    path
  end
end
