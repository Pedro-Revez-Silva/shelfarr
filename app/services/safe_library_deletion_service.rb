# frozen_string_literal: true

require "fiddle"
require "pathname"
require "rbconfig"

# Removes a Book's file or directory without ever resolving a library-owned
# path component through a symbolic link. The deletion root must come either
# from the current output settings or from durable import provenance.
class SafeLibraryDeletionService
  class Error < StandardError; end

  AT_REMOVEDIR = RbConfig::CONFIG.fetch("host_os").match?(/darwin/i) ? 0x80 : 0x200
  LINUX_RENAME_NOREPLACE = 0x1
  DARWIN_RENAME_EXCL = 0x4
  INTERNAL_DIRECTORIES = [
    OwnedMediaImportFileService::STAGING_DIRECTORY,
    UploadImportFileService::PRIVATE_DIRECTORY
  ].freeze

  def initialize(book)
    @book = book
    @path = Pathname(book.file_path.to_s).expand_path
  end

  def delete!
    root, relative = authorized_root_and_relative!
    parts = relative.each_filename.to_a
    raise Error, "Shelfarr refuses to delete an output root" if parts.empty?

    with_pinned_absolute_directory(root) do |root_directory|
      with_pinned_relative_directory(root_directory, parts[0...-1]) do |parent|
        delete_entry!(parent, parts.last)
      end
    end
    true
  rescue Errno::ENOENT
    # A path which was authorized from durable provenance and is already gone
    # needs no further filesystem work.
    true
  rescue Errno::ELOOP, Errno::EACCES, Errno::ENOTDIR, Errno::EPERM => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  rescue SystemCallError => error
    raise Error, "Shelfarr could not safely remove the library path: #{error.message}"
  end

  private

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
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      []
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
      rescue ArgumentError
        nil
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
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      nil
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
  rescue ArgumentError
    nil
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

  def delete_entry!(parent, basename)
    interrupted = quarantined_entries(parent)
    descriptor = begin
      native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
    rescue Errno::ENOENT
      return recover_quarantined_entry!(parent)
    end
    if interrupted.any?
      raise Error, "An interrupted deletion exists beside the current library path"
    end
    entry = IO.new(descriptor, "rb", autoclose: true)
    stat = entry.stat
    unless stat.file? || stat.directory?
      raise Error, "Shelfarr refuses to remove a symbolic link or special library entry"
    end
    entry.close

    quarantine = quarantine_basename(stat)
    unless native_rename_noreplace(parent.fileno, basename, parent.fileno, quarantine)
      raise Error, "This filesystem cannot atomically quarantine a library deletion"
    end
    sync_directory(parent)
    begin
      delete_quarantined_entry!(parent, quarantine, expected_identity: file_identity(stat))
    rescue
      restore_quarantined_entry(parent, quarantine, basename)
      raise
    end
  rescue Errno::ELOOP, Errno::ENXIO, Errno::ENODEV, Errno::EOPNOTSUPP
    raise Error, "Shelfarr refuses to remove a symbolic link or special library entry"
  ensure
    entry&.close unless entry&.closed?
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
    delete_quarantined_entry!(parent, basename, expected_identity: identity)
  end

  def restore_quarantined_entry(parent, quarantine, original)
    return unless native_rename_noreplace(parent.fileno, quarantine, parent.fileno, original)

    sync_directory(parent)
  rescue SystemCallError
    # Retaining the quarantine is safer than replacing a concurrently restored
    # original path. A later retry can reconcile its encoded inode identity.
    nil
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
    [ match[1].to_i, match[2].to_i ] if match
  end

  def quarantined_entries(parent)
    children_for(parent).filter_map do |entry|
      identity = quarantined_identity(entry)
      [ entry, identity ] if identity
    end
  end

  def sync_directory(directory)
    directory.fsync
  rescue Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
    nil
  end

  def file_identity(stat)
    [ stat.dev, stat.ino ]
  end

  def children_for(directory)
    duplicate = directory.dup
    listing = Dir.for_fd(duplicate.fileno)
    duplicate.autoclose = false
    listing.each_child.to_a
  ensure
    listing&.close
    duplicate&.close unless duplicate&.closed?
  end

  def native_openat(directory_fd, basename, flags)
    call_native(
      native_function(
        :openat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT ]
      ),
      directory_fd,
      basename,
      flags,
      0
    )
  end

  def native_unlinkat(directory_fd, basename, flags)
    call_native(
      native_function(
        :unlinkat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
      ),
      directory_fd,
      basename,
      flags
    )
  end

  def native_rename_noreplace(source_fd, source_basename, destination_fd, destination_basename)
    function, arguments = if RUBY_PLATFORM.include?("darwin")
      [
        :renameatx_np,
        [ source_fd, source_basename, destination_fd, destination_basename, DARWIN_RENAME_EXCL ]
      ]
    elsif RUBY_PLATFORM.include?("linux")
      [
        :renameat2,
        [ source_fd, source_basename, destination_fd, destination_basename, LINUX_RENAME_NOREPLACE ]
      ]
    else
      return false
    end
    signature = [
      Fiddle::TYPE_INT,
      Fiddle::TYPE_VOIDP,
      Fiddle::TYPE_INT,
      Fiddle::TYPE_VOIDP,
      Fiddle::TYPE_UINT
    ]
    call_native(native_function(function, signature), *arguments)
    true
  rescue Fiddle::DLError, Errno::ENOSYS, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
    false
  end

  def call_native(function, *arguments)
    pointers = arguments.map do |argument|
      argument.is_a?(String) ? Fiddle::Pointer[argument + "\0"] : argument
    end
    Fiddle.last_error = 0
    result = function.call(*pointers)
    return result unless result == -1

    raise SystemCallError.new("filesystem operation", Fiddle.last_error)
  end

  def native_function(name, arguments)
    @native_functions ||= {}
    @native_functions[name] ||= Fiddle::Function.new(
      Fiddle::Handle::DEFAULT[name.to_s],
      arguments,
      Fiddle::TYPE_INT
    )
  end
end
