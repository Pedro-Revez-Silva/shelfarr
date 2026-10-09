# frozen_string_literal: true

# Root identities authorize reference files independently of request history.
class LibraryDownloadRoots
  class UnavailableRootError < StandardError; end

  def initialize(book)
    @book = book
  end

  def preserve_legacy_reference_roots!
    return if !book.acquired? || book.reference_target_roots_recorded?

    # A missing client root may be temporarily unmounted. Keep its provenance
    # recoverable rather than deleting history and permanently forgetting it.
    client_download_paths.each do |path|
      canonical = Pathname(path).expand_path.realpath
      next if canonical.root?

      FileCopyService.snapshot_reference_root(canonical)
    rescue SystemCallError, ArgumentError, FileCopyService::UnsafePathError
      raise UnavailableRootError, "A download source is unavailable. Restore it before deleting request history, or remove the book from the Library."
    end

    roots = reference_target_roots
    book.update!(reference_target_roots: roots) if roots.any?
  end

  def output_roots
    canonicalize_roots(allowed_output_paths)
  end

  def reference_target_roots
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

  private

  attr_reader :book

  def allowed_output_paths
    [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path),
      SettingsService.get(:comicbook_output_path)
    ].compact.reject(&:blank?)
  end

  def allowed_download_paths
    [
      SettingsService.get(:download_local_path, default: "/downloads"),
      SettingsService.get(:download_remote_path),
      *client_download_paths
    ].compact_blank
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

  def client_download_paths
    book.requests
      .joins(downloads: :download_client)
      .where.not(download_clients: { download_path: [ nil, "" ] })
      .pluck("download_clients.download_path")
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
end
