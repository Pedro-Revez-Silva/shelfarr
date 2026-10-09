# frozen_string_literal: true

# Root identities authorize reference files independently of request history.
class LibraryDownloadRoots
  class UnavailableRootError < StandardError; end
  MAX_REFERENCE_ENTRIES = 10_000

  def initialize(book)
    @book = book
  end

  def preserve_legacy_reference_roots!
    return if !book.acquired? || book.reference_target_roots_recorded?

    references = legacy_reference_leaves
    return if references.empty?

    # Capture once and retain those identities. Re-querying after a directory
    # disappears can silently freeze a partial authorization set on the Book.
    roots = reference_target_roots
    references.each do |leaf|
      target = leaf.realpath
      root = roots.select { |candidate| contained?(target, candidate.path) }
        .max_by { |candidate| candidate.path.to_s.length }
      raise FileCopyService::UnsafePathError, "unavailable reference root" unless root

      FileCopyService.with_regular_file(target, root: root.path, authorized_root_snapshot: root) { |_file| }
    end

    book.update!(reference_target_roots: roots)
  rescue SystemCallError, ArgumentError, FileCopyService::UnsafePathError
    raise UnavailableRootError, "A download source is unavailable. Restore it before deleting request history, or remove the book from the Library."
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

  def legacy_reference_leaves
    path = Pathname(book.file_path)
    stat = path.lstat
    return [ path ] if stat.symlink?
    return [] unless stat.directory?

    references = []
    pending = [ path ]
    count = 0
    until pending.empty?
      directory = pending.pop
      directory.each_child do |child|
        count += 1
        raise UnavailableRootError, "This library item has too many entries to safely remove its request history." if
          count > MAX_REFERENCE_ENTRIES

        child_stat = child.lstat
        next if !child_stat.directory? && LibraryDestinationOccupancy.foreign_media?(child.basename.to_s, book)

        if child_stat.symlink?
          references << child
        elsif child_stat.directory?
          pending << child
        end
      end
    end
    references
  rescue Errno::ENOENT
    # A manually removed copied file needs no reference provenance. When
    # client-backed history exists, keep it until its contents can be inspected.
    raise unless client_download_paths.empty?

    []
  end

  def contained?(path, root)
    path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
  end

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
