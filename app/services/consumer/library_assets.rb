# frozen_string_literal: true

require "digest"

# A read-only bridge over the existing acquired library. Asset IDs identify an
# exact file generation, independently of the legacy work/format Book record.
# Canonical paths and reference provenance share the existing web-download rules.
#
# Reading publications (ebook and comic records) list only the formats a
# caller can open. The default is EPUB, exactly as before fixed-layout support,
# so installed readers and Kobo never see, or wait on, a PDF or CBZ beside
# their book. A PDF or CBZ that fails its basic format check is left out
# rather than offered: it would never open.
class Consumer::LibraryAssets
  include LibraryFileDownload

  class Unavailable < StandardError; end
  class Unusable < StandardError; end
  Asset = Data.define(:id, :path, :root, :device, :inode, :filename, :format, :media_type, :size_bytes, :position, :page_count)
  AUDIO_TYPES = { "mp3" => "audio/mpeg", "m4b" => "audio/mp4", "m4a" => "audio/mp4",
    "aac" => "audio/aac", "ogg" => "audio/ogg", "opus" => "audio/ogg", "flac" => "audio/flac", "wav" => "audio/wav" }.freeze
  READING_TYPES = { "epub" => "application/epub+zip", "kepub" => "application/epub+zip",
    "pdf" => "application/pdf", "cbz" => "application/vnd.comicbook+zip" }.freeze
  READING_LIMITS = { "epub" => 250.megabytes, "pdf" => 500.megabytes, "cbz" => 2.gigabytes }.freeze
  MAX_ENTRIES = 2_000
  MAX_DEPTH = 8
  PDF_HEADER_WINDOW = 1024
  # Inspected comic generations (asset ID => page count). Asset IDs change with
  # the file's size, inode and change time, so a hit is the same bytes.
  INSPECTED_LIMIT = 512
  @inspected = {}
  @inspected_lock = Mutex.new

  class << self
    def inspected(id)
      @inspected_lock.synchronize { @inspected[id] }
    end

    def remember_inspection(id, page_count)
      @inspected_lock.synchronize do
        @inspected.delete(id)
        @inspected[id] = page_count
        @inspected.shift while @inspected.size > INSPECTED_LIMIT
      end
    end
  end

  # formats: reading formats to list (Consumer::ReaderFormats names). Audio
  # publications always list their tracks.
  def initialize(book, formats: Consumer::ReaderFormats::DEFAULT)
    @book = book
    @formats = formats
  end

  def list
    candidates.each_with_index.filter_map { |path, index| asset_for(path, index) }
      .each_with_index.map { |asset, position| asset.with(position: position) }
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError, EncodingError
    raise Unavailable, "Media is missing or outside the authorized library"
  end

  # The listed asset with this exact ID. Every candidate's identity is checked,
  # but only the match is inspected.
  def find(asset_id)
    raise Unavailable, "This media edition has changed; refresh the publication" unless asset_id.to_s.match?(/\A[0-9a-f]{64}\z/)

    positions = 0
    candidates.each do |path|
      asset = asset_for(path, positions, inspect: false)
      next unless asset

      return asset_for(path, positions) if asset.id == asset_id

      positions += 1
    end
    nil
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError, EncodingError
    raise Unavailable, "Media is missing or outside the authorized library"
  end

  def open(asset_id)
    asset = find(asset_id)
    raise Unavailable, "This media edition has changed; refresh the publication" unless asset

    file = FileCopyService.open_pinned_regular_file(asset.path, root: asset.root,
      expected_device: asset.device, expected_inode: asset.inode)
    unless asset.id == identity(file.stat, asset.path)
      file.close
      raise Unavailable, "This media edition changed while opening"
    end
    [ asset, file ]
  rescue FileCopyService::UnsafePathError, SystemCallError, ArgumentError
    file&.close unless file&.closed?
    raise Unavailable, "This media edition is unavailable"
  end

  # The authoritative CBZ page order, read from the opened generation itself.
  def reading_order(asset_id)
    asset, file = open(asset_id)
    raise Unavailable, "This asset has no page list" unless asset.format == "cbz"

    [ asset, Consumer::ComicArchive.pages(file) ]
  rescue Consumer::ComicArchive::Invalid
    raise Unavailable, "This comic archive is unsupported or unsafe"
  ensure
    file&.close unless file&.closed?
  end

  private

  def download_book
    @book
  end

  def reading?
    @book.ebook? || @book.comicbook?
  end

  def candidates
    raise Unavailable, "This publication has no local media" unless @book.acquired? && (reading? || @book.audiobook?)

    boundary = canonical_download_boundary(@book.file_path)
    paths = boundary.kind == :file ? [ @book.file_path ] : directory_files(boundary)
    paths.select { |path| media_type(path) }.sort_by { |path| natural_key(path) }
  end

  def directory_files(boundary)
    raise Unavailable, "This publication shares the library root; select a book-specific file or folder" if boundary.target == boundary.root

    files = []
    pending = [ [ boundary.target, 0 ] ]
    count = 0
    until pending.empty?
      directory, depth = pending.pop
      raise Unavailable, "This publication exceeds the folder depth limit" if depth > MAX_DEPTH

      current = canonical_download_boundary(directory)
      raise Unavailable, "Publication folder changed" unless current.kind == :directory

      Dir.each_child(current.target) do |name|
        count += 1
        raise Unavailable, "This publication contains too many entries" if count > MAX_ENTRIES
        next if name.start_with?(".")

        path = File.join(current.target, name)
        stat = File.lstat(path)
        if stat.directory?
          pending << [ path, depth + 1 ]
        elsif media_type(path)
          files << path
        end
      end
    end
    files
  end

  # nil when a PDF or CBZ fails its format check: it is not offered at all.
  def asset_for(path, position, inspect: true)
    boundary = canonical_download_boundary(path)
    raise Unavailable, "Publication contains a non-file media entry" unless boundary.kind == :file

    file = FileCopyService.open_pinned_regular_file(boundary.target, root: boundary.root,
      expected_device: boundary.device, expected_inode: boundary.inode)
    stat = file.stat
    kind = format(path)
    id = identity(stat, boundary.target)
    raise Unavailable, "EPUBs larger than 250 MiB are not supported" if kind == "epub" && stat.size > READING_LIMITS["epub"]

    page_count = nil
    if %w[pdf cbz].include?(kind)
      return nil if stat.size > READING_LIMITS.fetch(kind)

      page_count = inspect ? inspection(kind, file, id) : 0
      return nil if RemoteResult.failed?(page_count)
    end

    Asset.new(id: id, path: boundary.target, root: boundary.root,
      device: stat.dev, inode: stat.ino, filename: FilenameBytes.utf8(File.basename(path)),
      format: kind, media_type: media_type(path), size_bytes: stat.size, position: position,
      page_count: kind == "cbz" ? page_count : nil)
  ensure
    file&.close unless file&.closed?
  end

  # A PDF must start with its header; a CBZ must have a valid bounded page
  # list. Returns the CBZ page count, 0 for a PDF, or a failure when unusable.
  def inspection(kind, file, id)
    if kind == "pdf"
      return 0 if file.pread(PDF_HEADER_WINDOW, 0).to_s.b.match?(/%PDF-\d\.\d/n)

      raise Unusable, "This file has no PDF header"
    end

    cached = self.class.inspected(id)
    return cached if cached

    count = Consumer::ComicArchive.pages(file).size
    self.class.remember_inspection(id, count)
    count
  rescue Consumer::ComicArchive::Invalid, Unusable, EOFError => error
    RemoteResult::Failed.new(error)
  end

  def identity(stat, path)
    Digest::SHA256.hexdigest([ @book.id, @book.file_path, path, stat.dev, stat.ino,
      stat.size, stat.mtime.to_r, stat.ctime.to_r ].join("\0"))
  end

  def media_type(path)
    extension = File.extname(path).delete_prefix(".").downcase
    if @book.audiobook?
      AUDIO_TYPES[extension]
    elsif @formats.include?(extension == "kepub" ? "epub" : extension)
      READING_TYPES[extension]
    end
  end

  def format(path)
    extension = File.extname(path).delete_prefix(".").downcase
    return extension if @book.audiobook?

    extension == "kepub" ? "epub" : extension
  end

  def natural_key(path)
    FilenameBytes.utf8(path).downcase.split(/(\d+)/).each_with_index.map { |part, index| index.odd? ? part.to_i : part }
  end
end
