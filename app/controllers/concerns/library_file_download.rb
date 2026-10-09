# frozen_string_literal: true

# Both request history and upload-only library entries use the same pinned-file
# delivery and configured-root checks. Controllers supply the book and redirect.
module LibraryFileDownload
  class UnsafeDownloadPathError < StandardError; end
  DownloadBoundary = Data.define(:target, :root, :device, :inode, :kind)
  MAX_ARCHIVE_DOWNLOAD_FILENAME_BYTES = 120

  private

  def serve_library_book_download
    book = download_book

    unless book.acquired? && book.file_path.present?
      redirect_to download_failure_location, alert: "This book is not available for download"
      return
    end

    begin
      boundary = canonical_download_boundary(book.file_path)
    rescue Errno::ENOENT
      redirect_to download_failure_location, alert: "File not found on server"
      return
    rescue UnsafeDownloadPathError, SystemCallError, ArgumentError
      Rails.logger.warn(
        "[Security] Rejected unsafe library download path for #{download_log_context}"
      )
      redirect_to download_failure_location, alert: "Invalid file path"
      return
    end

    if boundary.kind == :directory
      # Books imported with a blank path template share the output root as
      # their file_path; zipping it would bundle the entire library
      if boundary.target == boundary.root
        redirect_to download_failure_location, alert: "This book was imported directly into the library folder and cannot be downloaded as a bundle"
        return
      end

      send_zipped_directory(boundary.target, book, output_root: boundary.root)
    else
      send_single_file(boundary, book)
    end
  end


  def send_single_file(boundary, book)
    path = boundary.target
    filename = File.basename(path)
    file = FileCopyService.open_pinned_regular_file(
      path,
      root: boundary.root,
      expected_device: boundary.device,
      expected_inode: boundary.inode
    )
    send_pinned_file(
      file,
      filename: filename,
      type: Marcel::MimeType.for(name: filename) || "application/octet-stream"
    )
  rescue Errno::ENOENT, ActionController::MissingFile
    file&.close unless file&.closed?
    redirect_to download_failure_location, alert: "File not found on server"
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError
    file&.close unless file&.closed?
    Rails.logger.warn(
      "[Security] Rejected changed library download target for #{download_log_context}"
    )
    redirect_to download_failure_location, alert: "Invalid file path"
  end

  def send_zipped_directory(path, book, output_root:)
    zip_filename = archive_download_filename(book)
    cached_zip_path = LibraryDownloadArchiveService.call(
      book: book,
      source_path: path,
      output_root: output_root
    )

    cache_stat = File.lstat(cached_zip_path)
    cache_file = FileCopyService.open_pinned_regular_file(
      cached_zip_path,
      root: LibraryDownloadArchiveService::CACHE_DIRECTORY.to_s,
      expected_device: cache_stat.dev,
      expected_inode: cache_stat.ino
    )
    send_pinned_file(cache_file, filename: zip_filename, type: "application/zip")
  rescue LibraryDownloadArchiveService::UnsafePathError => e
    cache_file&.close unless cache_file&.closed?
    # Reference-mode trees contain authorized library symlinks the archive
    # service intentionally rejects; stream a one-shot zip of those targets.
    if e.message.to_s.include?("symbolic link")
      send_reference_tree_zip(path, book, output_root: output_root, zip_filename: zip_filename)
    else
      Rails.logger.error "[Download] Error creating zip for book ##{book.id}: #{e.class}"
      redirect_to download_failure_location, alert: "Library files changed while preparing the download. Please try again."
    end
  rescue LibraryDownloadArchiveService::ResourceLimitError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.warn "[Download] Archive resource limit for book ##{book.id}: #{e.class}"
    redirect_to download_failure_location, alert: "This library item exceeds the safe archive limits and cannot be bundled."
  rescue LibraryDownloadArchiveService::BusyError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.warn "[Download] Archive capacity unavailable for book ##{book.id}: #{e.class}"
    redirect_to download_failure_location, alert: "Archive preparation is busy. Please try again shortly."
  rescue LibraryDownloadArchiveService::Error, FileCopyService::UnsafePathError,
    ActionController::MissingFile, SystemCallError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.error "[Download] Error creating zip for book ##{book.id}: #{e.class}"
    redirect_to download_failure_location, alert: "Library files changed while preparing the download. Please try again."
  end

  def send_reference_tree_zip(path, book, output_root:, zip_filename:)
    require "zip"
    require "tempfile"

    root = Pathname(output_root).expand_path.realpath
    source = Pathname(path).expand_path
    raise UnsafeDownloadPathError, "reference tree outside library root" unless
      canonical_path_contained?(source.realpath.to_s, root.to_s) || source.realpath == root

    entries = collect_authorized_reference_entries(source, library_root: root, book: book)
    raise UnsafeDownloadPathError, "reference tree has no downloadable entries" if entries.empty?

    tmp = Tempfile.new([ "shelfarr-ref-", ".zip" ])
    tmp.binmode
    tmp.close
    Zip::File.open(tmp.path, create: true) do |zip|
      entries.each do |entry_name, target_path, content_root|
        zip.get_output_stream(entry_name) do |out|
          root_snapshot = content_root if content_root.is_a?(FileCopyService::ReferenceRootSnapshot)
          FileCopyService.with_regular_file(
            target_path,
            root: root_snapshot ? root_snapshot.path : content_root,
            authorized_root_snapshot: root_snapshot
          ) do |input|
            IO.copy_stream(input, out)
          end
        end
      end
    end
    archive_stat = File.lstat(tmp.path)
    archive_file = FileCopyService.open_pinned_regular_file(
      tmp.path,
      root: File.dirname(tmp.path),
      expected_device: archive_stat.dev,
      expected_inode: archive_stat.ino
    )
    send_pinned_file(archive_file, filename: zip_filename, type: "application/zip")
    archive_file = nil
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, Zip::Error => e
    Rails.logger.warn "[Download] Reference tree zip failed for book ##{book.id}: #{e.class}"
    redirect_to download_failure_location, alert: "Unable to prepare a download for this reference library item."
  ensure
    archive_file&.close unless archive_file&.closed?
    tmp&.close!
  end

  def collect_authorized_reference_entries(directory, library_root:, book:, prefix: nil)
    results = []
    Dir.each_child(directory) do |name|
      child = directory.join(name)
      relative = prefix ? File.join(prefix, name) : name
      stat = File.lstat(child)
      next if !stat.directory? && LibraryDestinationOccupancy.foreign_media?(name, book)
      if stat.directory?
        results.concat(
          collect_authorized_reference_entries(child, library_root: library_root, book: book, prefix: relative)
        )
      elsif stat.symlink?
        target = Pathname(File.readlink(child))
        target = child.parent.join(target) unless target.absolute?
        real = target.expand_path.realpath
        raise UnsafeDownloadPathError, "reference leaf is not a file" unless File.lstat(real).file?
        content_root = authorized_reference_target_roots.select do |root|
          canonical_path_contained?(real.to_s, root.path.to_s)
        end.max_by { |root| root.path.to_s.length }
        raise UnsafeDownloadPathError, "reference leaf escapes authorized roots" unless content_root

        results << [ relative, real.to_s, content_root ]
      elsif stat.file?
        real = child.realpath
        content_root = canonical_output_roots.select do |root|
          canonical_path_contained?(real.to_s, root.to_s)
        end.max_by { |root| root.to_s.length }
        raise UnsafeDownloadPathError, "library file escapes authorized roots" unless content_root

        results << [ relative, real.to_s, content_root.to_s ]
      else
        raise UnsafeDownloadPathError, "unsupported library entry type"
      end
    end
    results
  end

  def send_pinned_file(file, filename:, type:)
    body = PinnedFileResponseBody.new(file)
    send_file_headers!(filename: filename, type: type, disposition: "attachment")
    headers["Content-Length"] = file.stat.size.to_s
    self.status = :ok
    self.response_body = body
    body = nil
  ensure
    body&.close
  end

  def archive_download_filename(book)
    extension = ".zip"
    byte_budget = MAX_ARCHIVE_DOWNLOAD_FILENAME_BYTES - extension.bytesize
    value = "#{book.author} - #{book.title}".encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: "_"
    ).unicode_normalize(:nfc)
    value = value.gsub(/[\/\\:*?"<>|\x00-\x1f\x7f]/, "_").strip
    value = "library-download" if value.blank?
    value = value.byteslice(0, byte_budget).to_s.force_encoding(Encoding::UTF_8).scrub("_")
    value = value.sub(/[ .]+\z/, "")
    value = "library-download" if value.blank?
    "#{value}#{extension}"
  end

  def canonical_download_boundary(path)
    raise UnsafeDownloadPathError, "library path is blank" if path.blank?

    expanded = Pathname(path).expand_path
    link_stat = File.lstat(expanded)
    return reference_download_boundary(expanded) if link_stat.symlink?

    canonical_target = expanded.realpath
    target_stat = File.lstat(canonical_target)
    kind = if target_stat.file?
      :file
    elsif target_stat.directory?
      :directory
    else
      raise UnsafeDownloadPathError, "library target is not a regular file or directory"
    end

    canonical_root = canonical_output_roots.select do |root|
      canonical_path_contained?(canonical_target.to_s, root.to_s)
    end.max_by { |root| root.to_s.length }
    raise UnsafeDownloadPathError, "library path resolves outside configured roots" unless canonical_root

    DownloadBoundary.new(
      target: canonical_target.to_s,
      root: canonical_root.to_s,
      device: target_stat.dev,
      inode: target_stat.ino,
      kind: kind
    )
  end

  # Reference import mode publishes library leaves as symlinks to download
  # paths. Authorize the library pathname under output roots, then open the
  # resolved target only if it sits under a configured library or download root.
  def reference_download_boundary(library_path)
    library_parent = library_path.parent.realpath
    library_entry = library_parent.join(library_path.basename)
    library_root = canonical_output_roots.select do |root|
      canonical_path_contained?(library_parent.to_s, root.to_s) || library_parent == root
    end.max_by { |root| root.to_s.length }
    raise UnsafeDownloadPathError, "reference library path is outside configured roots" unless library_root

    target = Pathname(File.readlink(library_entry))
    target = library_parent.join(target) unless target.absolute?
    canonical_target = target.expand_path.realpath
    target_stat = File.lstat(canonical_target)
    raise UnsafeDownloadPathError, "reference target is not a regular file" unless target_stat.file?

    content_root = authorized_reference_target_roots.select do |root|
      canonical_path_contained?(canonical_target.to_s, root.path.to_s)
    end.max_by { |root| root.path.to_s.length }
    raise UnsafeDownloadPathError, "reference target resolves outside authorized roots" unless content_root

    DownloadBoundary.new(
      target: canonical_target.to_s,
      root: content_root.path.to_s,
      device: target_stat.dev,
      inode: target_stat.ino,
      kind: :file
    )
  end

  def allowed_output_paths
    [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path),
      SettingsService.get(:comicbook_output_path)
    ].compact.reject(&:blank?)
  end

  def allowed_download_paths
    client_paths = download_book.requests
      .joins(downloads: :download_client)
      .where.not(download_clients: { download_path: [ nil, "" ] })
      .pluck("download_clients.download_path")
    [
      SettingsService.get(:download_local_path, default: "/downloads"),
      SettingsService.get(:download_remote_path),
      *client_paths
    ].compact_blank
  end

  def canonical_path_contained?(path, root)
    return true if path == root

    root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
    path.start_with?(root_prefix)
  end

  def canonical_output_roots
    canonicalize_roots(allowed_output_paths)
  end

  def authorized_reference_target_roots
    book = download_book
    if book.reference_target_roots_recorded?
      validate_persisted_reference_target_roots(book.reference_target_roots)
    else
      canonicalize_roots(allowed_output_paths + allowed_download_paths).filter_map do |path|
        FileCopyService.snapshot_reference_root(path)
      rescue FileCopyService::UnsafePathError
        nil
      end
    end
  end

  def validate_persisted_reference_target_roots(roots)
    roots.filter_map do |root|
      path = Pathname(root.path)
      stat = File.lstat(path)
      next unless stat.directory?
      next unless [ stat.dev, stat.ino ] == [ root.device, root.inode ]

      FileCopyService::ReferenceRootSnapshot.new(
        path: path,
        device: root.device,
        inode: root.inode
      ).freeze
    rescue SystemCallError, ArgumentError
      nil
    end
  end

  def canonicalize_roots(paths)
    paths.filter_map do |configured_root|
      candidate = Pathname(configured_root).expand_path.realpath
      next if candidate.root?
      next unless candidate.lstat.directory?

      candidate
    rescue SystemCallError, ArgumentError
      nil
    end.uniq
  end

  def download_log_context
    "book ##{download_book.id}"
  end
end
