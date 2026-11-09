# frozen_string_literal: true

require "zip"

# Reuse the web download's canonical root and reference-import authorization.
# Only the already-open descriptor is read; rubyzip never reopens its pathname.
class KoboPublication
  include LibraryFileDownload

  class Unavailable < StandardError; end
  MAX_ENTRIES = 1_000
  MAX_XML_BYTES = 1024 * 1024
  MAX_EPUB_BYTES = 250.megabytes

  # rubyzip uses an IO's #path for entry reads if present. A File created
  # from a descriptor has a nil path, and a normal File would be reopened.
  # This adapter exposes only stream operations and duplicates the descriptor
  # when rubyzip opens an entry, so closing that entry keeps our pin alive.
  class ArchiveIO
    extend Forwardable
    def_delegators :@file, :size, :read, :seek, :tell, :pos, :eof, :eof?, :close, :closed?, :binmode

    def initialize(file)
      @file = file
    end

    def dup
      self.class.new(@file.dup)
    end
  end

  def initialize(book)
    @book = book
  end

  def snapshot
    file = open_file
    before = fingerprint(file)
    package_version = validate_epub(file)
    raise Unavailable, "The ebook changed; try sending it again" unless before == fingerprint(file)

    {
      "fingerprint" => before, "size" => file.stat.size,
      "filename" => @filename, "format" => @filename.match?(/\.kepub(?:\.epub)?\z/i) ? "KEPUB" : "EPUB",
      "epub_version" => package_version,
      "title" => @book.title, "author" => @book.author, "description" => @book.description.to_s.first(20_000)
    }
  rescue Zip::Error, Nokogiri::XML::SyntaxError, IOError
    raise Unavailable, "This file is not a valid EPUB"
  ensure
    file&.close unless file&.closed?
  end

  def open_file(expected_fingerprint: nil)
    raise Unavailable, "Choose an acquired ebook" unless @book.ebook? && @book.acquired?

    path = publication_path
    boundary = canonical_download_boundary(path)
    raise Unavailable, "Choose a single EPUB file" unless boundary.kind == :file

    @filename = File.basename(path)
    file = FileCopyService.open_pinned_regular_file(boundary.target, root: boundary.root,
      expected_device: boundary.device, expected_inode: boundary.inode)
    raise Unavailable, "EPUB files must be no larger than 250 MiB" if file.stat.size > MAX_EPUB_BYTES
    if expected_fingerprint && fingerprint(file) != expected_fingerprint
      raise Unavailable, "The ebook changed; send it to your Kobo again"
    end
    file
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError
    file&.close unless file&.closed?
    raise Unavailable, "The EPUB is missing or outside the authorized library"
  rescue Unavailable
    file&.close unless file&.closed?
    raise
  end

  def cover(file)
    with_archive(file) do |zip|
      package_path, package = package_document(zip)
      cover_id = package.at_xpath("//*[local-name()='meta'][@name='cover']/@content")&.value
      item = package.xpath("//*[local-name()='manifest']/*[local-name()='item']").find do |entry|
        entry["id"] == cover_id || entry["properties"].to_s.split.include?("cover-image")
      end
      return unless item && %w[image/jpeg image/png].include?(item["media-type"])

      href = item["href"].to_s
      return if href.match?(%r{\A/|:|\\}) || href.include?("\0")

      path = Pathname(File.dirname(package_path)).join(URI::DEFAULT_PARSER.unescape(href)).cleanpath.to_s
      return if path.start_with?("../")

      [ read_entry(zip, path, 4.megabytes), item["media-type"] ]
    end
  rescue Zip::Error, Nokogiri::XML::SyntaxError, IOError, ArgumentError
    raise Unavailable, "This EPUB cover is unavailable"
  end

  # Spine resources of the open edition, keyed by their decoded ZIP-root path.
  # Values keep the manifest's own (URL-encoded) spelling, which is what the
  # web reader saves as a locator href. Unsafe or missing items are skipped.
  def reading_order(file)
    with_archive(file) do |zip|
      package_path, package = package_document(zip)
      base = Pathname(File.dirname(package_path))
      manifest = package.xpath("//*[local-name()='manifest']/*[local-name()='item']").index_by { |item| item["id"] }
      package.xpath("//*[local-name()='spine']/*[local-name()='itemref']").each_with_object({}) do |reference, order|
        item = manifest[reference["idref"]]
        href = item&.[]("href").to_s.sub(/[?#].*\z/, "")
        next if href.empty? || href.match?(%r{\A/|:|\\}) || href.include?("\0")

        decoded = URI::DEFAULT_PARSER.unescape(href)
        next if decoded.match?(/[\x00-\x1f]/)

        path = base.join(decoded).cleanpath.to_s
        next if path.start_with?("../") || path == ".."

        order[path] ||= { "href" => base.join(href).cleanpath.to_s, "type" => item["media-type"].presence || "application/xhtml+xml" }
      end.then { |order| { "package_dir" => base.to_s, "items" => order } }
    end
  rescue Zip::Error, Nokogiri::XML::SyntaxError, IOError, ArgumentError, EncodingError
    raise Unavailable, "This EPUB's reading order is unavailable"
  end

  private

  def download_book
    @book
  end

  def publication_path
    boundary = canonical_download_boundary(@book.file_path)
    if boundary.kind == :file
      raise Unavailable, "Kobo sync supports EPUB files only" unless epub?(@book.file_path)

      return @book.file_path
    end
    raise Unavailable, "Select a book with its own folder or EPUB file" if boundary.target == boundary.root

    candidates = []
    pending = [ [ boundary.target, 0 ] ]
    count = 0
    until pending.empty?
      directory, depth = pending.shift
      raise Unavailable, "The book folder is too deeply nested" if depth > 5

      current = canonical_download_boundary(directory)
      raise Unavailable, "The book folder changed" unless current.kind == :directory

      Dir.each_child(current.target) do |name|
        count += 1
        raise Unavailable, "The book folder contains too many files" if count > MAX_ENTRIES

        path = File.join(current.target, name)
        stat = File.lstat(path)
        if stat.directory?
          pending << [ path, depth + 1 ]
        elsif epub?(name)
          candidates << path
          raise Unavailable, "The book folder contains multiple EPUBs; select a single-file library item" if candidates.size > 1
        end
      end
    end
    candidates.first || raise(Unavailable, "No EPUB found in this book's folder")
  end

  def epub?(path)
    path.match?(/\.(?:epub|kepub)\z/i)
  end

  def fingerprint(file)
    stat = file.stat
    Digest::SHA256.hexdigest([ @book.file_path, @filename, stat.dev, stat.ino, stat.size,
      stat.mtime.to_r, stat.ctime.to_r ].join("\0"))
  end

  def validate_epub(file)
    with_archive(file) do |zip|
      raise Unavailable, "Encrypted EPUBs are not supported" if zip.find_entry("META-INF/encryption.xml")
      raise Unavailable, "This file is not an EPUB" unless read_entry(zip, "mimetype", 64).strip == "application/epub+zip"

      _, package = package_document(zip)
      package.at_xpath("/*[local-name()='package']/@version")&.value ||
        raise(Unavailable, "This EPUB has no package version")
    end
  end

  def with_archive(file)
    raise Unavailable, "This EPUB contains too many entries" if Zip::File.count_entries(file) > MAX_ENTRIES

    zip = Zip::File.open_buffer(ArchiveIO.new(file))
    yield zip
  ensure
    zip&.close
  end

  def package_document(zip)
    container = parse_xml(read_entry(zip, "META-INF/container.xml", MAX_XML_BYTES))
    path = container.at_xpath("//*[local-name()='rootfile']/@full-path")&.value
    raise Unavailable, "This EPUB has no package document" if path.blank?

    [ path, parse_xml(read_entry(zip, path, MAX_XML_BYTES)) ]
  end

  def read_entry(zip, name, limit)
    entry = zip.find_entry(name)
    raise Unavailable, "This EPUB is incomplete or exceeds safe metadata limits" unless entry && entry.size <= limit && !entry.encrypted?

    entry.get_input_stream do |input|
      data = input.read(limit + 1)
      raise Unavailable, "This EPUB is incomplete or exceeds safe metadata limits" if data.nil? || data.empty? || data.bytesize > limit

      data
    end
  end

  def parse_xml(data)
    document = Nokogiri::XML(data) { |config| config.strict.nonet }
    raise Unavailable, "EPUB metadata must not contain a document type" if document.internal_subset

    document
  end
end
