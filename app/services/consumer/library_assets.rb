# frozen_string_literal: true

require "digest"

# A read-only bridge over the existing acquired library. Asset IDs identify an
# exact file generation, independently of the legacy work/format Book record.
# Canonical paths and reference provenance share the existing web-download rules.
class Consumer::LibraryAssets
  include LibraryFileDownload

  class Unavailable < StandardError; end
  Asset = Data.define(:id, :path, :root, :device, :inode, :filename, :format, :media_type, :size_bytes, :position)
  AUDIO_TYPES = { "mp3" => "audio/mpeg", "m4b" => "audio/mp4", "m4a" => "audio/mp4",
    "aac" => "audio/aac", "ogg" => "audio/ogg", "opus" => "audio/ogg", "flac" => "audio/flac", "wav" => "audio/wav" }.freeze
  MAX_ENTRIES = 2_000
  MAX_DEPTH = 8

  def initialize(book)
    @book = book
  end

  def list
    raise Unavailable, "This publication has no local media" unless @book.acquired? && (@book.ebook? || @book.audiobook?)

    boundary = canonical_download_boundary(@book.file_path)
    paths = boundary.kind == :file ? [ @book.file_path ] : directory_files(boundary)
    paths.select { |path| media_type(path) }.sort_by { |path| natural_key(path) }.each_with_index.map do |path, index|
      asset_for(path, index)
    end
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError, EncodingError
    raise Unavailable, "Media is missing or outside the authorized library"
  end

  def open(asset_id)
    raise Unavailable, "This media edition has changed; refresh the publication" unless asset_id.to_s.match?(/\A[0-9a-f]{64}\z/)

    asset = list.find { |entry| entry.id == asset_id }
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

  private

  def download_book
    @book
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

  def asset_for(path, position)
    boundary = canonical_download_boundary(path)
    raise Unavailable, "Publication contains a non-file media entry" unless boundary.kind == :file

    file = FileCopyService.open_pinned_regular_file(boundary.target, root: boundary.root,
      expected_device: boundary.device, expected_inode: boundary.inode)
    stat = file.stat
    raise Unavailable, "EPUBs larger than 250 MiB are not supported" if @book.ebook? && stat.size > 250.megabytes

    Asset.new(id: identity(stat, boundary.target), path: boundary.target, root: boundary.root,
      device: stat.dev, inode: stat.ino, filename: FilenameBytes.utf8(File.basename(path)),
      format: format(path), media_type: media_type(path), size_bytes: stat.size, position: position)
  ensure
    file&.close unless file&.closed?
  end

  def identity(stat, path)
    Digest::SHA256.hexdigest([ @book.id, @book.file_path, path, stat.dev, stat.ino,
      stat.size, stat.mtime.to_r, stat.ctime.to_r ].join("\0"))
  end

  def media_type(path)
    extension = File.extname(path).delete_prefix(".").downcase
    if @book.ebook?
      "application/epub+zip" if %w[epub kepub].include?(extension)
    else
      AUDIO_TYPES[extension]
    end
  end

  def format(path)
    return "epub" if @book.ebook?

    File.extname(path).delete_prefix(".").downcase
  end

  def natural_key(path)
    FilenameBytes.utf8(path).downcase.split(/(\d+)/).each_with_index.map { |part, index| index.odd? ? part.to_i : part }
  end
end
