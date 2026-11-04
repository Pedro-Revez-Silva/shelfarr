# frozen_string_literal: true

require "fiddle"
require "pathname"
require "rbconfig"

# Removes a Book's file or directory without ever resolving a library-owned
# path component through a symbolic link. The deletion root must come either
# from the current output settings or from durable import provenance.
class SafeLibraryDeletionService
  class Error < StandardError; end

  def self.same_or_nested_path?(child, parent)
    child_path = Pathname(child.to_s).expand_path
    parent_path = Pathname(parent.to_s).expand_path
    return true if child_path == parent_path

    relative = child_path.relative_path_from(parent_path)
    relative.to_s != ".." && !relative.to_s.start_with?("..#{File::SEPARATOR}")
  rescue ArgumentError => error
    RemoteResult::Failed.new(error)
  end

  def self.overlapping_library_paths?(left, right)
    [ same_or_nested_path?(left, right), same_or_nested_path?(right, left) ].any? do |result|
      result == true || RemoteResult.failed?(result)
    end
  end

  # The previous library path is removed only after the Book row points at the
  # new file. A new file inside the old directory is left in place.
  def self.delete_previous_library_file!(book, previous_path)
    current = book.file_path.to_s
    return false if previous_path.blank? || current.blank?
    return false if overlapping_library_paths?(current, previous_path)
    return true if LibraryDestinationOccupancy.overlaps_acquired_book?(previous_path, except_book_id: book.id)

    record = book.class.find_by(id: book.id)
    return false unless record

    record.file_path = previous_path
    new(record).delete!
    true
  rescue Error => error
    Rails.logger.warn(
      "[SafeLibraryDeletionService] Kept the previous library file for book ##{book.id}: #{error.class}"
    )
    RemoteResult::Failed.new(error)
  end

  AT_REMOVEDIR = RbConfig::CONFIG.fetch("host_os").match?(/darwin/i) ? 0x80 : 0x200
  INTERNAL_DIRECTORIES = LibraryPathSafety::INTERNAL_DIRECTORIES

  def initialize(book)
    @book = book
    @path = Pathname(book.file_path.to_s).expand_path
  end

  def delete!
    root, relative = authorized_root_and_relative!
    parts = relative.each_filename.to_a
    raise Error, "Shelfarr refuses to delete an output root" if parts.empty?
    operation = lambda do
      if LibraryDestinationOccupancy.overlaps_acquired_book?(@path, except_book_id: @book.id)
        raise Error, "This library path belongs to another acquired book"
      end
      if LibraryDestinationOccupancy.shared_directory?(@path, @book)
        raise Error, "This library folder contains another book's files; remove only this format's files manually"
      end
      with_pinned_absolute_directory(root) do |root_directory|
        with_pinned_relative_directory(root_directory, parts[0...-1]) do |parent|
          delete_entry!(parent, parts.last, protect_shared: true)
        end
      end
    end
    if File.directory?(@path) && !File.symlink?(@path)
      OwnedMediaImportFileService.with_lock(root, "destination-#{root.join(relative)}", &operation)
    else
      operation.call
    end
    true
  rescue OwnedMediaImportFileService::Error => error
    raise Error, "Shelfarr could not coordinate library deletion: #{error.message}"
  rescue Errno::ENOENT
    # A path which was authorized from durable provenance and is already gone needs no further filesystem work.
    true
  rescue Errno::ELOOP, Errno::EACCES, Errno::ENOTDIR, Errno::EPERM => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  rescue SystemCallError => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  rescue EncodingError => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  end

  # Removes the entry only if it is still the one this proof describes.
  # Returns :removed, :absent, or :retained. Anything else at the path, including
  # a parent that is no longer the one published into, is left alone. The check
  # is repeated after the name is claimed, so a swap between the check and the
  # claim is restored instead of deleted.
  def delete_proven_publication!(proof, deadline: nil)
    with_pinned_parent do |parent, basename|
      next :retained unless FileCopyService.publication_parent_matches?(proof, parent.stat)
      next :retained unless FileCopyService.stable_hardlink_identity?(parent)

      unless proof.fetch("kind") == "file" && proof["exclusive_inode"] == true
        # Target-only symlink proofs and shared hardlink inodes cannot prove
        # who created a name. Legacy file proofs lack that guarantee too.
        interrupted = if proof.fetch("kind") == "file"
          entry_present?(parent, "#{quarantine_prefix}#{proof.fetch('device')}-#{proof.fetch('inode')}") == true
        else
          quarantined_entries(parent).any? { |_name, identity| identity.first == :reference }
        end
        raise Error, "An unproven library entry stays quarantined for manual review" if interrupted

        next :retained
      end

      remove_proven_file!(parent, basename, proof, deadline: deadline)
    end
  rescue Errno::ENOENT
    :absent
  rescue Errno::ELOOP, Errno::ENOTDIR
    :retained
  rescue SystemCallError => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  end

  # rmdir is the emptiness check. A file created at any moment before it wins,
  # and the directory stays. Returns :removed, :absent, or :retained.
  def remove_empty_directory!
    if LibraryDestinationOccupancy.overlaps_acquired_book?(@path, except_book_id: @book.id) ||
        LibraryDestinationOccupancy.shared_directory?(@path, @book)
      return :retained
    end

    with_pinned_parent do |parent, basename|
      native_unlinkat(parent.fileno, basename, AT_REMOVEDIR)
      sync_directory(parent)
      :removed
    end
  rescue Errno::ENOENT
    :absent
  rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ELOOP, Errno::ENOTDIR
    :retained
  rescue SystemCallError => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  end

  private

  def with_pinned_parent
    root, relative = authorized_root_and_relative!
    parts = relative.each_filename.to_a
    raise Error, "Shelfarr refuses to delete an output root" if parts.empty?

    with_pinned_absolute_directory(root) do |root_directory|
      with_pinned_relative_directory(root_directory, parts[0...-1]) do |parent|
        yield parent, parts.last
      end
    end
  end

  def remove_proven_file!(parent, basename, proof, deadline:)
    interrupted = "#{quarantine_prefix}#{proof.fetch('device')}-#{proof.fetch('inode')}"
    return remove_claimed_file!(parent, interrupted, basename, proof, deadline: deadline) if entry_present?(parent, interrupted) == true

    entry = IO.new(
      native_openat(parent.fileno, basename, File::RDONLY | File::NOFOLLOW | File::NONBLOCK),
      "rb",
      autoclose: true
    )
    stat = entry.stat
    entry.close
    return :retained unless FileCopyService.publication_identity_matches?(proof, stat)

    claimed = quarantine_basename(stat)
    quarantine_library_entry!(parent, basename, claimed, directory: false)
    sync_directory(parent)
    remove_claimed_file!(parent, claimed, basename, proof, deadline: deadline)
  rescue Errno::ENXIO, Errno::ENODEV, Errno::EOPNOTSUPP
    :retained
  ensure
    entry&.close unless entry&.closed?
  end

  def remove_claimed_file!(parent, claimed, basename, proof, deadline:)
    descriptor = begin
      native_openat(parent.fileno, claimed, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
    rescue Errno::ELOOP
      return restore_claimed_entry!(parent, claimed, basename)
    end
    entry = File.for_fd(descriptor, "rb", autoclose: true)
    unless FileCopyService.publication_content_matches?(proof, entry, deadline: deadline)
      entry.close
      return restore_claimed_entry!(parent, claimed, basename)
    end
    identity = file_identity(entry.stat)
    entry.close

    verify_quarantined_identity!(parent, claimed, identity)
    native_unlinkat(parent.fileno, claimed, 0)
    sync_directory(parent)
    :removed
  ensure
    entry&.close unless entry&.closed?
  end

  # A claimed entry that failed its proof belongs to someone else. If its name
  # was taken meanwhile it stays quarantined, and the caller keeps the journal
  # that explains it.
  def restore_claimed_entry!(parent, claimed, basename)
    unless rename_library_entry_noreplace(parent, claimed, basename, directory: false) == true
      raise Error, "A changed library entry stays quarantined for manual review"
    end

    sync_directory(parent)
    :retained
  rescue Errno::EEXIST
    raise Error, "A changed library entry stays quarantined for manual review"
  end

  def entry_present?(parent, basename)
    IO.new(native_openat(parent.fileno, basename, File::RDONLY | File::NOFOLLOW | File::NONBLOCK), "rb", autoclose: true).close
    true
  rescue Errno::ENOENT => error
    RemoteResult::Failed.new(error)
  rescue Errno::ELOOP
    true
  end

  def authorized_root_and_relative!
    candidates = current_root_pairs + upload_root_pairs + owned_import_root_pairs
    candidates.uniq.each do |raw_lexical_root, raw_canonical_root|
      next if raw_lexical_root.blank? || raw_canonical_root.blank?

      lexical_root = Pathname(raw_lexical_root).expand_path
      relative = @path.relative_path_from(lexical_root)
      next if relative.to_s.in?([ ".", ".." ]) ||
        relative.to_s.start_with?("..#{File::SEPARATOR}")
      next if INTERNAL_DIRECTORIES.include?(relative.each_filename.first)

      canonical_root = Pathname(raw_canonical_root).expand_path.realpath
      return [ canonical_root, relative ]
    rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      next
    end

    raise Error, "The book path is outside its current and recorded library roots"
  end

  def current_root_pairs
    [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path),
      SettingsService.get(:comicbook_output_path)
    ].compact_blank.flat_map do |root|
      canonical = Pathname(root).expand_path.realpath.to_s
      [ [ root, canonical ], [ canonical, canonical ] ]
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
      RemoteResult::Failed.new(error)
    end
  end

  def upload_root_pairs
    @book.uploads.where.not(destination_root: [ nil, "" ]).filter_map do |upload|
      canonical_root = Pathname(upload.destination_root).expand_path
      configured_root = Pathname(
        upload.destination_configured_root.presence || upload.destination_root
      ).expand_path
      canonical_paths = [ upload.destination_path, upload.library_path ].compact.map do |path|
        Pathname(path).expand_path
      end
      display_paths = canonical_paths.filter_map do |path|
        relative = path.relative_path_from(canonical_root)
        configured_root.join(relative)
      rescue ArgumentError => error
        RemoteResult::Failed.new(error)
      end
      next unless @path.in?(canonical_paths + display_paths) || @path.to_s == upload.file_path.to_s

      [
        [ configured_root.to_s, canonical_root.to_s ],
        [ canonical_root.to_s, canonical_root.to_s ]
      ]
    end
      .flatten(1)
  end

  def owned_import_root_pairs
    owned_imports.filter_map do |media_import|
      next unless @path.to_s.in?([ media_import.destination_path, media_import.library_path ].compact)

      staged_path = media_import.upload&.file_path
      next if staged_path.blank?

      root = staging_root_from(staged_path)
      next if root.blank?

      [ [ root, Pathname(root).expand_path.realpath.to_s ] ]
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
      RemoteResult::Failed.new(error)
    end
      .flatten(1)
  end

  def owned_imports
    item_ids = @book.owned_library_item_ids
    OwnedMediaImport
      .where(created_book_id: @book.id)
      .or(OwnedMediaImport.where(owned_library_item_id: item_ids))
      .includes(:upload)
  end

  def staging_root_from(raw_path)
    path = Pathname(raw_path).expand_path
    staging = path.ascend.find do |candidate|
      candidate.basename.to_s == OwnedMediaImportFileService::STAGING_DIRECTORY
    end
    staging&.parent&.to_s
  rescue ArgumentError => error
    RemoteResult::Failed.new(error)
  end

  def with_pinned_absolute_directory(path)
    handles = []
    current = File.open("/", File::RDONLY | File::NONBLOCK)
    handles << current
    Pathname(path).each_filename do |part|
      child = open_directory_child(current, part)
      handles << child
      current = child
    end
    yield current
  ensure
    handles&.reverse_each { |handle| handle.close unless handle.closed? }
  end

  def with_pinned_relative_directory(parent, parts)
    handles = []
    current = parent
    parts.each do |part|
      raise Error, "The book path contains an invalid component" if part.in?([ ".", ".." ])

      child = open_directory_child(current, part)
      handles << child
      current = child
    end
    yield current
  ensure
    handles&.reverse_each { |handle| handle.close unless handle.closed? }
  end

  def open_directory_child(parent, basename)
    descriptor = native_openat(
      parent.fileno,
      basename,
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
    directory = IO.new(descriptor, "rb", autoclose: true)
    unless directory.stat.directory?
      directory.close
      raise Error, "The book path contains a non-directory ancestor"
    end
    directory
  end

  def delete_entry!(parent, basename, protect_shared: false)
    interrupted = quarantined_entries(parent)
    descriptor = begin
      native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
    rescue Errno::ENOENT
      return recover_quarantined_entry!(parent)
    rescue Errno::ELOOP
      return delete_reference_symlink!(parent, basename, interrupted: interrupted)
    end
    if interrupted.any?
      raise Error, "An interrupted deletion exists beside the current library path"
    end
    entry = IO.new(descriptor, "rb", autoclose: true)
    stat = entry.stat
    unless stat.file? || stat.directory?
      raise Error, "Shelfarr refuses to remove a symbolic link or special library entry"
    end
    if protect_shared && stat.directory? && LibraryDestinationOccupancy.shared_directory?(@path, @book)
      raise Error, "This library folder contains another book's files; remove only this format's files manually"
    end
    entry.close

    quarantine = quarantine_basename(stat)
    directory = stat.directory?
    quarantine_library_entry!(parent, basename, quarantine, directory: directory)
    sync_directory(parent)
    begin
      delete_quarantined_entry!(parent, quarantine, expected_identity: file_identity(stat))
    rescue
      restore_quarantined_entry(parent, quarantine, basename, directory: directory)
      raise
    end
  rescue Errno::ENXIO, Errno::ENODEV, Errno::EOPNOTSUPP
    raise Error, "Shelfarr refuses to remove a symbolic link or special library entry"
  ensure
    entry&.close unless entry&.closed?
  end

  # Reference import mode stores library leaves as symlinks. Claim the name with
  # rename-noreplace into a book-scoped quarantine basename (recoverable after
  # crash), confirm it is still a symlink (openat O_NOFOLLOW → ELOOP), then
  # unlink without following the target.
  def delete_reference_symlink!(parent, basename, interrupted:)
    if interrupted.any?
      raise Error, "An interrupted deletion exists beside the current library path"
    end

    quarantine = "#{quarantine_prefix}ref-#{SecureRandom.hex(8)}"
    quarantine_library_entry!(parent, basename, quarantine, directory: false)
    sync_directory(parent)

    begin
      native_openat(
        parent.fileno,
        quarantine,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
      restore_quarantined_entry(parent, quarantine, basename, directory: false)
      raise Error, "Shelfarr refuses to remove a non-symlink library entry claimed as a reference"
    rescue Errno::ELOOP
      native_unlinkat(parent.fileno, quarantine, 0)
      sync_directory(parent)
      true
    rescue Errno::ENOENT
      true
    rescue
      restore_quarantined_entry(parent, quarantine, basename, directory: false)
      raise
    end
  end

  def delete_quarantined_entry!(parent, basename, expected_identity:)
    descriptor = native_openat(
      parent.fileno,
      basename,
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
    entry = IO.new(descriptor, "rb", autoclose: true)
    stat = entry.stat
    unless file_identity(stat) == expected_identity && (stat.file? || stat.directory?)
      raise Error, "The quarantined library entry changed before deletion"
    end

    if stat.directory?
      children_for(entry).each do |child|
        parsed_identity = quarantined_identity(child)
        if parsed_identity
          delete_quarantined_entry!(entry, child, expected_identity: parsed_identity)
        else
          delete_entry!(entry, child)
        end
      end
    end
    entry.close
    verify_quarantined_identity!(parent, basename, expected_identity)
    native_unlinkat(parent.fileno, basename, stat.directory? ? AT_REMOVEDIR : 0)
    sync_directory(parent)
    true
  ensure
    entry&.close unless entry&.closed?
  end

  def recover_quarantined_entry!(parent)
    matches = quarantined_entries(parent)
    return true if matches.empty?
    raise Error, "Multiple interrupted library deletions need manual review" if matches.many?

    basename, identity = matches.sole
    if identity.is_a?(Array) && identity.first == :reference
      finish_reference_quarantine!(parent, basename)
    else
      delete_quarantined_entry!(parent, basename, expected_identity: identity)
    end
  end

  def finish_reference_quarantine!(parent, basename)
    begin
      native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
      raise Error, "Interrupted reference quarantine is no longer a symlink"
    rescue Errno::ELOOP
      native_unlinkat(parent.fileno, basename, 0)
      sync_directory(parent)
      true
    rescue Errno::ENOENT
      true
    end
  end

  def restore_quarantined_entry(parent, quarantine, original, directory:)
    return unless rename_library_entry_noreplace(
      parent,
      quarantine,
      original,
      directory: directory
    ) == true

    sync_directory(parent)
  rescue SystemCallError => error
    # Retaining the quarantine is safer than replacing a concurrently restored
    # original path. A later retry can reconcile its encoded inode identity.
    RemoteResult::Failed.new(error)
  end

  def quarantine_library_entry!(parent, source_basename, destination_basename, directory:)
    renamed = rename_library_entry_noreplace(
      parent,
      source_basename,
      destination_basename,
      directory: directory
    )
    return if renamed == true
    raise Error, "The library quarantine name is already in use" if renamed == :occupied

    raise Error, "This filesystem cannot atomically quarantine a library deletion"
  end

  # NFSv4 rejects RENAME_NOREPLACE with EINVAL. A checked plain rename is
  # safe only under the same explicit single-writer policy used by imports.
  def rename_library_entry_noreplace(parent, source_basename, destination_basename, directory:)
    renamed = native_rename_noreplace(
      parent.fileno,
      source_basename,
      parent.fileno,
      destination_basename
    )
    return true if renamed == true
    return false unless noreplace_unsupported?(renamed)
    return false unless SettingsService.get(:allow_nonatomic_nfs_directory_publication)

    fallback = rename_noreplace_fallback(
      parent,
      source_basename,
      destination_basename,
      directory: directory
    )
    return true if fallback == true
    return :occupied if fallback == false || RemoteResult.failed?(fallback)

    false
  end

  def rename_noreplace_fallback(parent, source_basename, destination_basename, directory:)
    FileCopyService.send(
      :rename_entry_noreplace,
      parent,
      source_basename,
      destination_basename,
      allow_nonatomic: true,
      directory: directory
    )
  rescue FileCopyService::UnsafePathError, Errno::ELOOP => error
    RemoteResult::Failed.new(error)
  end

  def noreplace_unsupported?(result)
    RemoteResult.failed?(result) && result.error.is_a?(Errno::EINVAL)
  end

  def verify_quarantined_identity!(parent, basename, expected_identity)
    descriptor = native_openat(
      parent.fileno,
      basename,
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
    current = IO.new(descriptor, "rb", autoclose: true)
    unless file_identity(current.stat) == expected_identity
      raise Error, "The quarantined library entry changed during deletion"
    end
  ensure
    current&.close unless current&.closed?
  end

  def quarantine_basename(stat)
    "#{quarantine_prefix}#{stat.dev}-#{stat.ino}"
  end

  def quarantine_prefix
    ".shelfarr-delete-#{@book.id}-"
  end

  def quarantined_identity(basename)
    match = /\A#{Regexp.escape(quarantine_prefix)}(\d+)-(\d+)\z/.match(basename)
    return [ match[1].to_i, match[2].to_i ] if match

    match = /\A#{Regexp.escape(quarantine_prefix)}ref-([0-9a-f]+)\z/.match(basename)
    return [ :reference, match[1] ] if match

    nil
  end

  def quarantined_entries(parent)
    raw_children_for(parent).filter_map do |entry|
      identity = quarantined_identity(entry)
      [ FilenameBytes.utf8(entry), identity ] if identity
    end
  end

  def sync_directory(directory)
    directory.fsync
  rescue Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP => error
    RemoteResult::Failed.new(error)
  end

  def file_identity(stat)
    [ stat.dev, stat.ino ]
  end

  def children_for(directory)
    raw_children_for(directory).map { |entry| FilenameBytes.utf8(entry) }
  end

  def raw_children_for(directory)
    duplicate = directory.dup
    listing = Dir.for_fd(duplicate.fileno)
    duplicate.autoclose = false
    listing.each_child.to_a
  ensure
    listing&.close
    duplicate&.close unless duplicate&.closed?
  end

  def native_openat(directory_fd, basename, flags)
    FilesystemSyscalls.openat(directory_fd, basename, flags: flags)
  end

  def native_unlinkat(directory_fd, basename, flags)
    FilesystemSyscalls.unlinkat(directory_fd, basename, flags)
  end

  def native_readlinkat(directory_fd, basename)
    FilesystemSyscalls.readlinkat(directory_fd, basename)
  end

  def native_rename_noreplace(source_fd, source_basename, destination_fd, destination_basename)
    FilesystemSyscalls.rename_noreplace(source_fd, source_basename, destination_fd, destination_basename)
  rescue Errno::EINVAL => error
    RemoteResult::Failed.new(error)
  end
end
