# frozen_string_literal: true

require "fiddle"
require "pathname"
require "digest"

# NFS-safe file copy operations.
#
# Ruby's IO.copy_stream (used by FileUtils.cp/cp_r) attempts the
# copy_file_range syscall for efficient file-to-file copies. This syscall
# fails with Errno::EACCES on NFS mounts even when the user has full
# read/write permissions. This service catches that specific failure and
# falls back to a buffered read/write copy.
#
# See: https://github.com/Pedro-Revez-Silva/shelfarr/issues/131
class FileCopyService
  BUFFER_SIZE = 1024 * 1024 # 1 MB
  LIBRARY_FILE_MODE = 0o640
  DIRECTORY_MODE = 0o750
  COPY_LOCK_LEGACY_MAGIC = "shelfarr-copy-v1"
  COPY_LOCK_MAGIC = "shelfarr-copy-v2"
  COPY_LOCK_PATTERN = /\A\.shelfarr-copy-([0-9a-f]{32})\.lock\z/
  COPY_LOCK_LEGACY_PATTERN = /\A#{Regexp.escape(COPY_LOCK_LEGACY_MAGIC)}:([0-9a-f]{32})\z/
  COPY_LOCK_PENDING_PATTERN = /\A#{Regexp.escape(COPY_LOCK_MAGIC)}:([0-9a-f]{32}):pending\z/
  COPY_LOCK_RECORD_PATTERN = /\A#{Regexp.escape(COPY_LOCK_MAGIC)}:([0-9a-f]{32}):full:([0-9]+):([0-9]+)\z/
  COPY_LOCK_COMPATIBILITY_PREPARED_PATTERN = /\A#{Regexp.escape(COPY_LOCK_MAGIC)}:([0-9a-f]{32}):compatibility:prepared:([0-9]+):([0-9]+):([0-9a-f]+)\z/
  COPY_LOCK_COMPATIBILITY_PATTERN = /\A#{Regexp.escape(COPY_LOCK_MAGIC)}:([0-9a-f]{32}):compatibility:(copying|complete):([0-9]+):([0-9]+):([0-9]+):([0-9]+):([0-9a-f]+)\z/
  COPY_QUARANTINE_PATTERN = /\A\.shelfarr-copy-quarantine-([0-9a-f]+)-([0-9a-f]+)-([0-9a-f]{32})\z/
  COPY_QUARANTINE_ENTRY = "entry"
  COPY_QUARANTINE_STALE_AGE = 24 * 60 * 60
  LINUX_RENAME_NOREPLACE = 0x1
  DARWIN_RENAME_EXCL = 0x4
  AT_REMOVEDIR = RUBY_PLATFORM.include?("darwin") ? 0x80 : 0x200

  class UnsafePathError < StandardError; end
  class AtomicPublicationUnsupportedError < StandardError; end
  class HardlinkUnsupportedError < StandardError; end
  SourceRoot = Struct.new(
    :path,
    :canonical_path,
    :device,
    :inode,
    :size,
    :mtime,
    :ctime,
    :parent_path,
    :canonical_parent_path,
    :parent_device,
    :parent_inode,
    :entries,
    keyword_init: true
  )
  DirectoryChild = Struct.new(
    :name,
    :device,
    :inode,
    :type,
    :mtime,
    :parent_device,
    :parent_inode,
    keyword_init: true
  )
  PrivateFile = Struct.new(:io, :name, :device, :inode, keyword_init: true)

  class << self
    def cp(src, dest)
      FileUtils.cp(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered copy for #{File.basename(src)}"
      buffered_copy(src, dest)
    end

    # Copy a regular file through a complete private file in the destination
    # directory. Publication uses an atomic no-replace operation when the
    # filesystem supports one, or an exclusive descriptor-backed copy with
    # crash recovery on compatibility filesystems. Every destination component
    # is opened from a pinned root descriptor with O_NOFOLLOW.
    def cp_noreplace(
      src,
      dest,
      root: nil,
      source_root: nil,
      heartbeat: nil,
      hardlink_mode: false,
      allow_compatibility_fallback: false
    )
      source_opener = hardlink_mode ? :with_pinned_hardlink_source : :with_pinned_source
      send(source_opener, src, source_root: source_root) do |source, *_source_path|
        publish_source_io_noreplace(
          source,
          dest,
          root: root,
          heartbeat: heartbeat,
          allow_compatibility_fallback: allow_compatibility_fallback
        )
      end
      dest
    end

    # Hardlink a regular source without exposing a pathname selected by a
    # source race. The source name is first linked to a private destination
    # entry, which must match the already-open source descriptor before the
    # existing no-replace publication protocol can make it final.
    def hardlink_noreplace(src, dest, root:, source_root:)
      with_pinned_hardlink_source(src, source_root: source_root) do |source, source_parent, source_basename, source_parent_path, source_manifest|
        publish_hardlink_noreplace(
          source,
          source_parent,
          source_basename,
          source_parent_path,
          source_manifest,
          dest,
          root: root
        )
      end
      dest
    end

    # Publish from a source descriptor already pinned by the caller (for
    # example, a verified HTTP Tempfile) without resolving its pathname again.
    def cp_io_noreplace(source, dest, root: nil, heartbeat: nil)
      raise Errno::EINVAL, "source is not a regular file" unless source.stat.file?

      publish_source_io_noreplace(source, dest, root: root, heartbeat: heartbeat)
      dest
    end

    # Move with the same crash-safe publication as cp_noreplace. The source is
    # removed through its pinned parent descriptor only after its pathname,
    # descriptor identity, and parent identity have all been revalidated.
    def mv_noreplace(
      src,
      dest,
      root: nil,
      source_root: nil,
      heartbeat: nil,
      allow_compatibility_fallback: false
    )
      with_pinned_source(src, source_root: source_root) do |source, source_parent, source_basename, source_parent_path|
        source_identity = file_identity(source.stat)
        publish_source_io_noreplace(
          source,
          dest,
          root: root,
          heartbeat: heartbeat,
          allow_compatibility_fallback: allow_compatibility_fallback
        )
        remove_pinned_source_after_publication!(
          source,
          source_parent,
          source_basename,
          source_parent_path,
          source_identity
        )
      end
      dest
    end

    # Atomically publish a complete, regular-only directory tree. Unlike a
    # recursive copy this makes the tree visible at one instant and refuses to
    # merge with or replace any pre-existing destination.
    def mv_directory_noreplace(source, destination, root:, source_root: nil, heartbeat: nil)
      source_root ||= snapshot_source_root(source, heartbeat: heartbeat)
      source_path = Pathname(source).expand_path
      destination_path = Pathname(destination).expand_path

      with_pinned_absolute_directory(source_root.canonical_parent_path) do |source_parent|
        unless file_identity(source_parent.stat) == [ source_root.parent_device, source_root.parent_inode ]
          raise Errno::ESTALE, "source parent identity changed during publication"
        end
        validate_current_directory_identity!(source_root.parent_path, source_parent)

        source_directory = open_pinned_directory_child(source_parent, source_path.basename.to_s)
        begin
          unless file_identity(source_directory.stat) == [ source_root.device, source_root.inode ] &&
              snapshot_pinned_regular_tree(source_directory) == source_root.entries
            raise Errno::ESTALE, "source directory changed before publication"
          end
          secure_pinned_library_tree!(source_directory, heartbeat: heartbeat)

          with_pinned_destination_parent(destination_path, root: root) do |destination_parent, basename, parent_path|
            published = native_rename_noreplace(
              source_parent.fileno,
              source_path.basename.to_s,
              destination_parent.fileno,
              basename
            )
            unless published
              raise AtomicPublicationUnsupportedError,
                "The destination filesystem cannot atomically publish library directories"
            end

            expected_identity = [ source_root.device, source_root.inode ]
            unless pinned_child_identity(destination_parent, basename, directory: true) == expected_identity
              raise Errno::ESTALE, "published directory identity changed"
            end
            validate_current_directory_identity!(parent_path, destination_parent)
            sync_io(source_parent)
            sync_io(destination_parent)
          end
        ensure
          source_directory.close unless source_directory.closed?
        end
      end
      destination
    end

    # Content-only manifest used to reconcile a complete directory after a
    # worker exits between filesystem publication and database completion.
    def directory_content_manifest(path, root:, heartbeat: nil)
      manifest = {}
      with_pinned_directory(path, root: root, create: false, mode: DIRECTORY_MODE) do |directory|
        digest_pinned_regular_tree(directory, manifest: manifest, heartbeat: heartbeat)
      end
      manifest
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "directory contains a symbolic link or non-regular path: #{error.message}"
    end

    def file_content_manifest(path, root:, heartbeat: nil)
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |file|
          stat = file.stat
          digest = Digest::SHA256.new
          buffer = +""
          while file.read(BUFFER_SIZE, buffer)
            digest << buffer
            heartbeat&.call
          end
          validate_current_directory_identity!(parent_path, parent)
          return [ "file", stat.size, digest.hexdigest ]
        end
      end
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "file path contains a symbolic link or non-directory: #{error.message}"
    end

    # Create a destination directory relative to a trusted output root while
    # rejecting symlinks and non-directories in every path component.
    def ensure_directory(path, root:, mode: DIRECTORY_MODE)
      with_pinned_directory(path, root: root, create: true, mode: mode) do |directory|
        sync_io(directory)
      end
      path
    end

    def secure_private_directory!(path, root:)
      with_pinned_directory(path, root: root, create: true, mode: 0o700) do |directory|
        unless directory.stat.uid == Process.euid
          raise UnsafePathError, "private staging directory is owned by another user"
        end
        native_fchmod(directory.fileno, 0o700)
        sync_io(directory)
      end
      path
    end

    def create_private_directory(parent_path, root:, prefix:)
      unless prefix.match?(/\A[a-zA-Z0-9_-]+\z/)
        raise UnsafePathError, "private directory prefix is unsafe"
      end

      with_pinned_directory(parent_path, root: root, create: true, mode: 0o700) do |parent|
        unless parent.stat.uid == Process.euid
          raise UnsafePathError, "private staging parent is owned by another user"
        end
        native_fchmod(parent.fileno, 0o700)

        loop do
          basename = "#{prefix}#{SecureRandom.hex(16)}"
          begin
            native_mkdirat(parent.fileno, basename, 0o700)
          rescue Errno::EEXIST
            next
          end
          child = open_pinned_directory_child(parent, basename)
          begin
            native_fchmod(child.fileno, 0o700)
            sync_io(child)
            sync_io(parent)
            stat = child.stat
            parent_stat = parent.stat
            validate_current_directory_identity!(parent_path, parent)
            validate_current_directory_identity!(File.join(parent_path, basename), child)
            return DirectoryChild.new(
              name: File.join(parent_path, basename),
              device: stat.dev,
              inode: stat.ino,
              type: :directory,
              mtime: stat.mtime,
              parent_device: parent_stat.dev,
              parent_inode: parent_stat.ino
            )
          ensure
            child.close unless child.closed?
          end
        end
      end
    end

    # Create and return an already-open private regular file beneath a pinned
    # directory. Callers perform all I/O through the returned descriptor, so a
    # later ancestor rename or symlink swap cannot redirect staged bytes.
    def create_private_file(parent_path, root:, prefix:, suffix: "")
      unless prefix.match?(/\A\.?[a-zA-Z0-9_-]+\z/) && suffix.match?(/\A(?:\.[a-zA-Z0-9_-]+)?\z/)
        raise UnsafePathError, "private file name is unsafe"
      end

      with_pinned_directory(parent_path, root: root, create: false, mode: 0o700) do |parent|
        unless parent.stat.uid == Process.euid
          raise UnsafePathError, "private staging directory is owned by another user"
        end

        loop do
          basename = "#{prefix}#{SecureRandom.hex(16)}#{suffix}"
          descriptor = begin
            native_openat(
              parent.fileno,
              basename,
              File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW,
              0o600
            )
          rescue Errno::EEXIST
            next
          end
          file = File.for_fd(descriptor, "r+b", autoclose: true)
          identity = file_identity(file.stat)
          begin
            raise UnsafePathError, "created staging path is not a regular file" unless file.stat.file?

            native_fchmod(file.fileno, 0o600)
            flush_and_sync(file)
            validate_current_directory_identity!(parent_path, parent)
            with_pinned_regular_child(parent, basename) do |current|
              unless file_identity(current.stat) == identity
                raise Errno::ESTALE, "private staging file changed during creation"
              end
            end
            sync_io(parent)
            return PrivateFile.new(
              io: file,
              name: File.join(parent_path, basename),
              device: identity.first,
              inode: identity.last
            )
          rescue
            file.close unless file.closed?
            remove_pinned_child_if_identity(parent, basename, identity)
            sync_io(parent)
            raise
          end
        end
      end
    end

    # Coordinate work on a stable private pathname through a no-follow file
    # beneath a pinned directory. Lock files persist so separate processes can
    # never flock different inodes for the same logical lock.
    def with_private_lock(path, root:, nonblock: false)
      raise ArgumentError, "a lock block is required" unless block_given?

      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        attempts = 0
        descriptor = begin
          attempts += 1
          native_openat(
            parent.fileno,
            basename,
            File::RDWR | File::CREAT | File::NOFOLLOW,
            0o600
          )
        rescue Errno::ENOENT
          retry if attempts < 3

          raise
        end
        lock = File.for_fd(descriptor, "r+b", autoclose: true)
        begin
          stat = lock.stat
          unless stat.file? && stat.uid == Process.euid
            raise UnsafePathError, "private lock is not an application-owned regular file"
          end

          native_fchmod(lock.fileno, 0o600)
          lock_flags = File::LOCK_EX
          lock_flags |= File::LOCK_NB if nonblock
          acquired = begin
            lock.flock(lock_flags)
          rescue Errno::EWOULDBLOCK
            raise unless nonblock

            false
          end
          return false if nonblock && !acquired
          raise UnsafePathError, "private lock could not be acquired" unless acquired

          identity = file_identity(lock.stat)
          with_pinned_regular_child(parent, basename) do |current|
            raise Errno::ESTALE, "private lock changed before use" unless file_identity(current.stat) == identity
          end
          validate_current_directory_identity!(parent_path, parent)

          result = yield

          with_pinned_regular_child(parent, basename) do |current|
            raise Errno::ESTALE, "private lock changed during use" unless file_identity(current.stat) == identity
          end
          validate_current_directory_identity!(parent_path, parent)
          result
        ensure
          lock.close unless lock.closed?
        end
      end
    end

    # Open a regular file beneath a trusted root through no-follow parent
    # descriptors and transfer ownership of that exact descriptor to the
    # caller. The pathname may subsequently be replaced without changing the
    # bytes read from the returned descriptor.
    def open_pinned_regular_file(path, root:, expected_device:, expected_inode:)
      opened = nil
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        descriptor = native_openat(
          parent.fileno,
          basename,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
          0
        )
        candidate = File.for_fd(descriptor, "rb", autoclose: true)
        begin
          stat = candidate.stat
          unless stat.file? && [ stat.dev, stat.ino ] == [ expected_device, expected_inode ]
            raise Errno::ESTALE, "regular file changed after download authorization"
          end

          validate_current_directory_identity!(parent_path, parent)
          opened = candidate
          candidate = nil
        ensure
          candidate&.close unless candidate&.closed?
        end
      end
      opened
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "download path contains a symbolic link or non-directory: #{error.message}"
    end

    # Yield a regular file through a pinned parent and reject any identity/stat
    # change across the read.
    def with_regular_file(path, root:)
      raise ArgumentError, "a file block is required" unless block_given?

      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |file|
          expected = file_manifest_entry(file.stat)
          result = yield file
          raise Errno::ESTALE, "regular file changed during validation" unless file_manifest_entry(file.stat) == expected

          with_pinned_regular_child(parent, basename) do |current|
            raise Errno::ESTALE, "regular file changed after validation" unless file_manifest_entry(current.stat) == expected
          end
          validate_current_directory_identity!(parent_path, parent)
          result
        end
      end
    end

    # Refresh a regular file's cleanup lease through its pinned descriptor.
    # Identity is checked before and after futimes so a pathname replacement is
    # never refreshed on behalf of the validated file.
    def refresh_regular_file_times(path, root:)
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |file|
          identity = file_identity(file.stat)
          native_futimes_now(file.fileno)
          sync_io(file)
          with_pinned_regular_child(parent, basename) do |current|
            raise Errno::ESTALE, "regular file changed while its lease was refreshed" unless file_identity(current.stat) == identity
          end
          validate_current_directory_identity!(parent_path, parent)
        end
      end
      true
    end

    # Atomically publish a complete PrivateFile into the same pinned directory.
    # Publication is no-replace and uses the existing platform fallback.
    def publish_private_file_noreplace(private_file, destination, root:, mode: 0o600)
      source = Pathname(private_file.name).expand_path
      destination = Pathname(destination).expand_path
      unless source.parent == destination.parent && source.basename != destination.basename
        raise UnsafePathError, "private publication paths do not share a safe parent"
      end
      unless private_file.io.stat.file? && file_identity(private_file.io.stat) == [ private_file.device, private_file.inode ]
        raise Errno::ESTALE, "private publication descriptor changed"
      end

      native_fchmod(private_file.io.fileno, mode)
      flush_and_sync(private_file.io)
      with_pinned_destination_parent(destination, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, source.basename.to_s) do |current|
          unless file_identity(current.stat) == [ private_file.device, private_file.inode ]
            raise Errno::ESTALE, "private publication source changed"
          end

          publish_private_child_noreplace!(
            parent,
            source.basename.to_s,
            basename,
            [ private_file.device, private_file.inode ],
            mode: mode
          )
        end
        validate_published_child!(
          parent,
          basename,
          [ private_file.device, private_file.inode ],
          expected_mode: mode
        )
        validate_current_directory_identity!(parent_path, parent)
        sync_io(parent)
      end
      destination.to_s
    end

    # Remove only the still-identical staging pathname associated with a
    # PrivateFile. A replacement at the same name is retained.
    def remove_private_file(private_file, root:)
      source = Pathname(private_file.name).expand_path
      removed = false
      with_pinned_destination_parent(source, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |current|
          next unless file_identity(current.stat) == [ private_file.device, private_file.inode ]

          native_unlinkat(parent.fileno, basename)
          removed = true
        end
        validate_current_directory_identity!(parent_path, parent)
        sync_io(parent)
      end
      removed
    rescue Errno::ENOENT
      false
    end

    # Remove a regular file only after atomically moving it to a unique name
    # inside the same pinned private directory and verifying that the moved
    # entry is the inode inspected by this process.
    def remove_regular_file_safely(path, root:)
      path = Pathname(path).expand_path
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        expected_identity = nil
        with_pinned_regular_child(parent, basename) do |current|
          expected_identity = file_identity(current.stat)
        end

        quarantine = ".shelfarr-discard-#{SecureRandom.hex(16)}.tmp"
        renamed = native_rename_noreplace(
          parent.fileno,
          basename,
          parent.fileno,
          quarantine
        )
        unless renamed
          raise AtomicPublicationUnsupportedError,
            "The cache filesystem cannot atomically quarantine invalid files"
        end

        actual_identity = nil
        with_pinned_regular_child(parent, quarantine) do |current|
          actual_identity = file_identity(current.stat)
        end
        unless actual_identity == expected_identity
          restored = native_rename_noreplace(
            parent.fileno,
            quarantine,
            parent.fileno,
            basename
          )
          unless restored
            raise UnsafePathError, "a changed cache file was retained for manual review"
          end

          raise Errno::ESTALE, "cache file changed while it was quarantined"
        end

        native_unlinkat(parent.fileno, quarantine)
        validate_current_directory_identity!(parent_path, parent)
        sync_io(parent)
        true
      end
    rescue Errno::ENOENT
      false
    end

    # Safely materialize a regular staging file at a caller-validated relative
    # path. Every ancestor and the output itself stay pinned by descriptors for
    # the duration of the write. The incomplete file is unlinked on failure.
    def with_private_file_noreplace(staging_path, relative_path, root:)
      staging_path = Pathname(staging_path).expand_path
      relative = safe_relative_path(relative_path)
      raise UnsafePathError, "private file path must name a file" if relative.to_s == "."

      result = nil
      with_pinned_directory(staging_path, root: root, create: false, mode: 0o700) do |staging|
        with_pinned_relative_directory(staging, relative.dirname, create: true, mode: 0o700) do |parent|
          basename = relative.basename.to_s
          identity = nil
          begin
            with_created_regular_child(parent, basename, 0o600) do |output|
              identity = file_identity(output.stat)
              result = yield output
              native_fchmod(output.fileno, 0o600)
              flush_and_sync(output)
            end
            validate_current_directory_identity!(staging_path, staging)
            validate_current_directory_identity!(staging_path.join(relative.dirname), parent)
            with_pinned_regular_child(parent, basename) do |current|
              unless file_identity(current.stat) == identity
                raise Errno::ESTALE, "private staging file changed while it was written"
              end
            end
            sync_io(parent)
            sync_io(staging)
          rescue
            remove_pinned_child_if_identity(parent, basename, identity)
            sync_io(parent)
            raise
          end
        end
      end
      result
    end

    def ensure_private_relative_directory(staging_path, relative_path, root:)
      staging_path = Pathname(staging_path).expand_path
      relative = safe_relative_path(relative_path)

      with_pinned_directory(staging_path, root: root, create: false, mode: 0o700) do |staging|
        with_pinned_relative_directory(staging, relative, create: true, mode: 0o700) do |directory|
          native_fchmod(directory.fileno, 0o700)
          sync_io(directory)
          validate_current_directory_identity!(staging_path, staging)
          validate_current_directory_identity!(staging_path.join(relative), directory)
        end
        sync_io(staging)
      end
      staging_path.join(relative).to_s
    end

    def directory_children(path, root:)
      children = []
      with_pinned_directory(path, root: root, create: false, mode: DIRECTORY_MODE) do |directory|
        pinned_directory_children(directory).each do |entry|
          descriptor = native_openat(
            directory.fileno,
            entry,
            File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
            0
          )
          child = IO.new(descriptor, "rb", autoclose: true)
          begin
            stat = child.stat
            type = if stat.directory?
              :directory
            elsif stat.file?
              :file
            else
              :special
            end
            children << DirectoryChild.new(
              name: entry,
              device: stat.dev,
              inode: stat.ino,
              type: type,
              mtime: stat.mtime
            )
          ensure
            child.close unless child.closed?
          end
        rescue Errno::ENOENT, Errno::ELOOP
          next
        end
      end
      children
    end

    def directory_identity(path, root:)
      with_pinned_directory(path, root: root, create: false, mode: DIRECTORY_MODE) do |directory|
        stat = directory.stat
        return [ stat.dev, stat.ino ]
      end
    end

    def remove_directory_child_if_identity(parent_path, child_name, root:, device:, inode:)
      if child_name.include?(File::SEPARATOR) || child_name.in?([ ".", ".." ])
        raise UnsafePathError, "directory child name is unsafe"
      end

      parent_path = Pathname(parent_path).expand_path
      snapshot = nil
      with_pinned_directory(parent_path, root: root, create: false, mode: 0o700) do |parent|
        child = open_pinned_directory_child(parent, child_name)
        begin
          stat = child.stat
          return false unless [ stat.dev, stat.ino ] == [ device, inode ]

          canonical_parent = parent_path.realpath
          parent_stat = parent.stat
          snapshot = SourceRoot.new(
            path: parent_path.join(child_name),
            canonical_path: canonical_parent.join(child_name),
            device: stat.dev,
            inode: stat.ino,
            size: stat.size,
            mtime: stat.mtime.to_r,
            ctime: stat.ctime.to_r,
            parent_path: parent_path,
            canonical_parent_path: canonical_parent,
            parent_device: parent_stat.dev,
            parent_inode: parent_stat.ino,
            entries: snapshot_pinned_regular_tree(child).freeze
          ).freeze
          validate_current_directory_identity!(parent_path, parent)
          validate_current_directory_identity!(snapshot.path, child)
        ensure
          child.close unless child.closed?
        end
      end

      remove_source_tree(snapshot)
    rescue Errno::ENOENT, Errno::ESTALE, UnsafePathError
      false
    end

    # Compare regular files through pinned descriptors. This is used by retry
    # reconciliation so a path swap cannot trick an import into reusing an
    # unrelated library file.
    def same_file_content?(source_path, destination_path, root: nil, source_root: nil, hardlink_mode: false)
      source_opener = hardlink_mode ? :with_pinned_hardlink_source : :with_pinned_source
      result = nil
      send(source_opener, source_path, source_root: source_root) do |source, *_source_path|
        result = same_io_content?(source, destination_path, root: root)
      end
      result
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
      false
    end

    # Compare regular-file identities through pinned source and destination
    # descriptors. This distinguishes a reused hardlink from an independent
    # file with identical content without trusting either pathname alone.
    def same_file_identity?(source_path, destination_path, root:, source_root:, hardlink_mode: false)
      source_opener = hardlink_mode ? :with_pinned_hardlink_source : :with_pinned_source
      result = nil
      send(source_opener, source_path, source_root: source_root) do |source, *_source_path|
        source_identity = file_identity(source.stat)
        with_pinned_destination_parent(destination_path, root: root) do |parent, basename, parent_path|
          destination_identity = nil
          with_pinned_regular_child(parent, basename) do |destination|
            destination_identity = file_identity(destination.stat)
          end
          with_pinned_regular_child(parent, basename) do |current|
            unless file_identity(current.stat) == destination_identity
              raise Errno::ESTALE, "destination changed during identity validation"
            end
          end
          validate_current_directory_identity!(parent_path, parent)
          result = source_identity == destination_identity
        end
      end
      result
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
      false
    end

    # Check retry eligibility without chmodding a path that may be a hardlink
    # to retained download data. The pathname is reopened before returning so
    # a replacement cannot inherit the first descriptor's result.
    def secure_library_file_mode?(path, root:)
      result = false
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        expected_identity = nil
        expected_mode = nil
        with_pinned_regular_child(parent, basename) do |file|
          stat = file.stat
          expected_identity = file_identity(stat)
          expected_mode = stat.mode & 0o7777
          result = expected_mode == LIBRARY_FILE_MODE
        end
        with_pinned_regular_child(parent, basename) do |current|
          stat = current.stat
          unless file_identity(stat) == expected_identity && (stat.mode & 0o7777) == expected_mode
            raise Errno::ESTALE, "library file changed during mode validation"
          end
        end
        validate_current_directory_identity!(parent_path, parent)
      end
      result
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
      false
    end

    def same_io_content?(source, destination_path, root: nil)
      original_position = source.pos
      with_pinned_destination_parent(destination_path, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |destination|
          return false unless source.stat.file? && source.stat.size == destination.stat.size

          source.rewind
          destination.rewind
          result = compare_io(source, destination)
          validate_current_directory_identity!(parent_path, parent)
          return result
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
      false
    ensure
      source.seek(original_position) if original_position
    end

    # Yield a regular source file through the immutable directory snapshot that
    # authorized it. The descriptor remains pinned for the whole read and the
    # source identity/stat manifest is revalidated before and after the block.
    def with_source_file(path, source_root:)
      raise ArgumentError, "a source block is required" unless block_given?

      with_pinned_source(path, source_root: source_root) do |source, _parent, _basename, _parent_path|
        yield source
      end
    end

    # Snapshot and validate a directory tree through no-follow descriptors.
    # Later source opens can use the returned token to reject root replacement
    # and symlink swaps in every relative component.
    def snapshot_source_root(path, heartbeat: nil, max_entries: nil, max_depth: nil)
      expanded = Pathname(path).expand_path
      canonical = expanded.realpath
      parent_path = expanded.parent
      canonical_parent = parent_path.realpath
      parent_stat = File.lstat(canonical_parent)
      with_pinned_absolute_directory(canonical) do |directory|
        validate_current_directory_identity!(expanded, directory)
        raise UnsafePathError, "source root is not a directory" unless directory.stat.directory?

        entries = snapshot_pinned_regular_tree(
          directory,
          heartbeat: heartbeat,
          max_entries: max_entries,
          max_depth: max_depth
        )
        stat = directory.stat
        return SourceRoot.new(
          path: expanded,
          canonical_path: canonical,
          device: stat.dev,
          inode: stat.ino,
          size: stat.size,
          mtime: stat.mtime.to_r,
          ctime: stat.ctime.to_r,
          parent_path: parent_path,
          canonical_parent_path: canonical_parent,
          parent_device: parent_stat.dev,
          parent_inode: parent_stat.ino,
          entries: entries.freeze
        ).freeze
      end
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError,
        "source tree contains a symbolic link or non-regular path: #{error.message}"
    rescue Errno::ENOENT, Errno::EACCES => error
      raise UnsafePathError, "source tree is not safely accessible: #{error.message}"
    end

    # Atomically quarantine the current directory entry, verify that it is the
    # exact tree snapshotted before import, and only then remove it. If another
    # directory won the pathname race, restore or retain that replacement; it
    # is never recursively deleted.
    def remove_source_tree(source_root)
      expanded = source_root.path
      parent_path = source_root.parent_path
      canonical_parent = source_root.canonical_parent_path
      quarantine_basename = ".shelfarr-remove-#{SecureRandom.hex(16)}"

      with_pinned_absolute_directory(canonical_parent) do |parent|
        unless file_identity(parent.stat) == [ source_root.parent_device, source_root.parent_inode ]
          raise Errno::ESTALE, "source parent identity changed during cleanup"
        end
        validate_current_directory_identity!(parent_path, parent)
        renamed = native_rename_noreplace(
          parent.fileno,
          expanded.basename.to_s,
          parent.fileno,
          quarantine_basename
        )
        return false unless renamed

        quarantined_identity = pinned_child_identity(parent, quarantine_basename, directory: true)
        expected_identity = [ source_root.device, source_root.inode ]
        unless quarantined_identity == expected_identity
          restore_quarantined_replacement(parent, quarantine_basename, expanded.basename.to_s)
          return false
        end

        with_pinned_relative_directory(
          parent,
          Pathname(quarantine_basename),
          create: false
        ) do |quarantine|
          unless snapshot_pinned_regular_tree(quarantine) == source_root.entries
            restore_quarantined_replacement(parent, quarantine_basename, expanded.basename.to_s)
            return false
          end

          remove_pinned_tree_contents!(quarantine, source_root.entries)
        end

        validate_current_directory_identity!(parent_path, parent)
        unless pinned_child_identity(parent, quarantine_basename, directory: true) == expected_identity
          restore_quarantined_replacement(parent, quarantine_basename, expanded.basename.to_s)
          return false
        end
        native_unlinkat(parent.fileno, quarantine_basename, AT_REMOVEDIR)
        sync_io(parent)
        true
      end
    rescue Errno::ENOENT
      false
    end

    def secure_library_file!(path, root: nil)
      with_pinned_destination_parent(path, root: root) do |parent, basename, parent_path|
        with_pinned_regular_child(parent, basename) do |file|
          native_fchmod(file.fileno, LIBRARY_FILE_MODE)
          sync_io(file)
        end
        validate_current_directory_identity!(parent_path, parent)
        sync_io(parent)
      end
      path
    end

    # Reclaim private copy files left by a hard process exit. A unique lock
    # token is never reused, so unlinking a verified stale lock cannot weaken a
    # future publication's mutual exclusion.
    def cleanup_interrupted_copies(directory, root: nil)
      destination = File.join(directory, ".shelfarr-cleanup-probe")
      with_pinned_destination_parent(destination, root: root) do |parent, _basename, parent_path|
        validate_current_directory_identity!(parent_path, parent)
        Dir.children(parent_path).each do |entry|
          if (match = COPY_LOCK_PATTERN.match(entry))
            cleanup_interrupted_copy(parent, match[1])
          elsif (match = COPY_QUARANTINE_PATTERN.match(entry))
            cleanup_interrupted_quarantine(
              parent,
              entry,
              [ match[1].to_i(16), match[2].to_i(16) ]
            )
          end
        end
        validate_current_directory_identity!(parent_path, parent)
      end
      true
    rescue Errno::ENOENT
      true
    end

    # Legacy staging-only copy from an already-open source descriptor. This
    # writes directly to +dest+ and is not an atomic library publication API;
    # library callers must use cp_io_noreplace instead.
    def cp_io(source, dest)
      source.rewind
      File.open(dest, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) do |target|
        # Staging files are private application state. Never propagate
        # executable, set-id, or world-accessible bits from the companion.
        target.chmod(0o600)
        begin
          IO.copy_stream(source, target)
        rescue Errno::EACCES => e
          raise unless copy_file_range_error?(e)

          Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered descriptor copy"
          source.rewind
          target.rewind
          target.truncate(0)
          buffered_copy_io(source, target)
        end
        flush_and_sync(target)
      end
    end

    def cp_r(src, dest)
      FileUtils.cp_r(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered recursive copy"
      recursive_buffered_copy(src, dest)
    end

    def mv(src, dest)
      FileUtils.mv(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered move for #{File.basename(src)}"
      move_via_copy(src, dest)
    end

    private

    def safe_relative_path(path)
      relative = Pathname(path.to_s)
      if relative.absolute? || relative.each_filename.any? { |part| part.in?([ ".", ".." ]) }
        raise UnsafePathError, "private staging path is unsafe"
      end
      relative
    end

    def publish_source_io_noreplace(
      source,
      destination,
      root:,
      heartbeat: nil,
      allow_compatibility_fallback: false
    )
      raise Errno::EINVAL, "source is not a regular file" unless source.stat.file?

      cleanup_interrupted_copies(File.dirname(destination), root: root)
      with_pinned_destination_parent(destination, root: root) do |parent, basename, parent_path|
        token = SecureRandom.hex(16)
        temporary_basename = ".shelfarr-copy-#{token}.tmp"
        lock_basename = ".shelfarr-copy-#{token}.lock"
        temporary_identity = nil
        lock_identity = nil
        published_identity = nil

        begin
          with_created_regular_child(parent, lock_basename, 0o600) do |lock|
            lock_identity = file_identity(lock.stat)
            raise UnsafePathError, "copy lock could not be acquired" unless lock.flock(File::LOCK_EX)

            sync_io(parent)
            persist_copy_lock_pending!(lock, token)

            with_created_regular_child(parent, temporary_basename, 0o600) do |temporary|
              temporary_identity = file_identity(temporary.stat)
              persist_copy_lock_identity!(lock, token, temporary_identity)
              sync_io(parent)
              if heartbeat
                copy_source_io(source, temporary, heartbeat: heartbeat)
              else
                copy_source_io(source, temporary)
              end
              native_fchmod(temporary.fileno, LIBRARY_FILE_MODE)
              flush_and_sync(temporary)

              begin
                publish_private_child_noreplace!(
                  parent,
                  temporary_basename,
                  basename,
                  temporary_identity
                )
                published_identity = temporary_identity
              rescue AtomicPublicationUnsupportedError
                raise unless allow_compatibility_fallback

                Rails.logger.warn(
                  "[FileCopyService] Atomic publication unsupported; using exclusive-copy compatibility mode"
                )
                published_identity = publish_private_child_by_copy_noreplace!(
                  parent,
                  temporary_basename,
                  basename,
                  temporary_identity,
                  lock: lock,
                  token: token,
                  heartbeat: heartbeat
                )
              end
              validate_published_child!(parent, basename, published_identity)
              validate_current_directory_identity!(parent_path, parent)
              sync_io(parent)
            end
          end
        rescue
          # Once an atomic publication succeeds, retain the complete file on
          # any later validation/sync error. Check-then-unlink cleanup could
          # otherwise delete a replacement installed by another worker.
          raise
        ensure
          temporary_cleanup = remove_pinned_child_if_identity(
            parent,
            temporary_basename,
            temporary_identity
          )
          if temporary_cleanup.in?([ :removed, :missing ])
            remove_pinned_child_if_identity(parent, lock_basename, lock_identity)
          end
          sync_io(parent)
        end
      end
    end

    def publish_hardlink_noreplace(
      source,
      source_parent,
      source_basename,
      source_parent_path,
      source_manifest,
      destination,
      root:
    )
      source_identity = source_manifest.first(2)
      expected_stable_manifest = stable_hardlink_snapshot_entry(source_manifest)
      source_mode = expected_stable_manifest.last

      cleanup_interrupted_copies(File.dirname(destination), root: root)
      with_pinned_destination_parent(destination, root: root) do |parent, basename, parent_path|
        token = SecureRandom.hex(16)
        temporary_basename = ".shelfarr-copy-#{token}.tmp"
        lock_basename = ".shelfarr-copy-#{token}.lock"
        temporary_identity = nil
        lock_identity = nil

        begin
          with_created_regular_child(parent, lock_basename, 0o600) do |lock|
            lock_identity = file_identity(lock.stat)
            raise UnsafePathError, "copy lock could not be acquired" unless lock.flock(File::LOCK_EX)

            sync_io(parent)

            validate_hardlink_source!(
              source,
              source_parent,
              source_basename,
              source_parent_path,
              source_manifest
            )
            persist_copy_lock_identity!(lock, token, source_identity)
            begin
              native_linkat(
                source_parent.fileno,
                source_basename,
                parent.fileno,
                temporary_basename
              )
              temporary_identity = source_identity
            rescue Errno::EXDEV, Errno::EPERM, Errno::EOPNOTSUPP, Errno::ENOTSUP,
                Errno::ENOSYS, Errno::EMLINK, Fiddle::DLError, NotImplementedError => error
              raise HardlinkUnsupportedError,
                "The source and destination filesystems cannot create the requested hardlink",
                cause: error
            end

            with_pinned_regular_child(parent, temporary_basename) do |temporary|
              temporary_stat = temporary.stat
              unless file_identity(temporary_stat) == temporary_identity &&
                  stable_hardlink_manifest_entry(temporary_stat) == expected_stable_manifest
                raise Errno::ESTALE, "private hardlink does not match the pinned source"
              end
            end
            sync_io(parent)

            validate_hardlink_source!(
              source,
              source_parent,
              source_basename,
              source_parent_path,
              source_manifest
            )
            validate_current_directory_identity!(parent_path, parent)

            publish_private_child_noreplace!(
              parent,
              temporary_basename,
              basename,
              temporary_identity,
              mode: source_mode
            )
            validate_published_child!(
              parent,
              basename,
              source_identity,
              expected_mode: source_mode,
              expected_manifest: source_manifest
            )
            validate_hardlink_source!(
              source,
              source_parent,
              source_basename,
              source_parent_path,
              source_manifest
            )
            validate_current_directory_identity!(parent_path, parent)
            sync_io(parent)
          end
        ensure
          temporary_cleanup = remove_pinned_child_if_identity(
            parent,
            temporary_basename,
            temporary_identity
          )
          if temporary_cleanup.in?([ :removed, :missing ])
            remove_pinned_child_if_identity(parent, lock_basename, lock_identity)
          end
          sync_io(parent)
        end
      end
    end

    def validate_hardlink_source!(
      source,
      parent,
      basename,
      parent_path,
      expected_manifest
    )
      expected = stable_hardlink_snapshot_entry(expected_manifest)
      unless stable_hardlink_manifest_entry(source.stat) == expected
        raise Errno::ESTALE, "source file changed during hardlink publication"
      end

      validate_current_directory_identity!(parent_path, parent)
      with_pinned_regular_child(parent, basename) do |current|
        unless stable_hardlink_manifest_entry(current.stat) == expected
          raise Errno::ESTALE, "source path changed during hardlink publication"
        end
      end
    end

    def copy_source_io(source, target, heartbeat: nil)
      source.rewind
      if heartbeat
        buffer = +""
        while source.read(BUFFER_SIZE, buffer)
          target.write(buffer)
          heartbeat.call
        end
        return
      end

      begin
        IO.copy_stream(source, target)
      rescue Errno::EACCES => error
        raise unless copy_file_range_error?(error)

        Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered descriptor copy"
        source.rewind
        target.rewind
        target.truncate(0)
        buffered_copy_io(source, target)
      end
    end

    def publish_private_child_noreplace!(parent, temporary_basename, destination_basename, identity, mode: LIBRARY_FILE_MODE)
      native_linkat(
        parent.fileno,
        temporary_basename,
        parent.fileno,
        destination_basename
      )
    rescue Errno::EPERM, Errno::EOPNOTSUPP, Errno::ENOTSUP, Errno::ENOSYS, Errno::EMLINK,
        Fiddle::DLError, NotImplementedError
      result = native_rename_noreplace(
        parent.fileno,
        temporary_basename,
        parent.fileno,
        destination_basename
      )
      unless result
        raise AtomicPublicationUnsupportedError,
          "The destination filesystem cannot atomically publish library files"
      end

      validate_published_child!(parent, destination_basename, identity, expected_mode: mode)
    end

    def publish_private_child_by_copy_noreplace!(
      parent,
      temporary_basename,
      destination_basename,
      temporary_identity,
      lock:,
      token:,
      heartbeat:,
      mode: LIBRARY_FILE_MODE
    )
      destination_identity = nil
      source_size = nil

      begin
        with_pinned_regular_child(parent, temporary_basename) do |source|
          source_stat = source.stat
          unless file_identity(source_stat) == temporary_identity
            raise Errno::ESTALE, "private publication source changed"
          end
          source_size = source_stat.size

          persist_copy_lock_compatibility!(
            lock,
            token,
            :prepared,
            temporary_identity,
            destination_basename
          )
          with_created_regular_child(parent, destination_basename, 0o600) do |destination|
            destination_identity = file_identity(destination.stat)
            persist_copy_lock_compatibility!(
              lock,
              token,
              :copying,
              temporary_identity,
              destination_basename,
              destination_identity
            )
            sync_io(parent)

            if heartbeat
              copy_source_io(source, destination, heartbeat: heartbeat)
            else
              copy_source_io(source, destination)
            end
            native_fchmod(destination.fileno, mode)
            flush_and_sync(destination)
            unless file_identity(source.stat) == temporary_identity &&
                source.stat.size == source_size && destination.stat.size == source_size
              raise Errno::ESTALE, "file changed during compatibility publication"
            end
          end
        end

        with_pinned_regular_child(parent, temporary_basename) do |source|
          unless file_identity(source.stat) == temporary_identity && source.stat.size == source_size
            raise Errno::ESTALE, "private publication source changed"
          end
        end
        validate_published_child!(
          parent,
          destination_basename,
          destination_identity,
          expected_mode: mode
        )
        sync_io(parent)
        persist_copy_lock_compatibility!(
          lock,
          token,
          :complete,
          temporary_identity,
          destination_basename,
          destination_identity
        )
        destination_identity
      rescue
        remove_pinned_child_if_identity(parent, destination_basename, destination_identity)
        sync_io(parent)
        raise
      end
    end

    def validate_published_child!(
      parent,
      basename,
      expected_identity,
      expected_mode: LIBRARY_FILE_MODE,
      expected_manifest: nil
    )
      with_pinned_regular_child(parent, basename) do |published|
        stat = published.stat
        unless file_identity(stat) == expected_identity
          raise Errno::ESTALE, "destination changed during no-clobber publication"
        end
        unless (stat.mode & 0o7777) == expected_mode
          raise UnsafePathError, "published library file permissions changed"
        end
        if expected_manifest &&
            stable_hardlink_manifest_entry(stat) != stable_hardlink_snapshot_entry(expected_manifest)
          raise Errno::ESTALE, "published hardlink changed during no-clobber publication"
        end
      end
    end

    def remove_pinned_source_after_publication!(source, parent, basename, parent_path, expected_identity)
      unless file_identity(source.stat) == expected_identity
        raise Errno::ESTALE, "source changed during no-clobber move"
      end
      validate_current_directory_identity!(parent_path, parent)

      with_pinned_regular_child(parent, basename) do |current|
        unless file_identity(current.stat) == expected_identity
          raise Errno::ESTALE, "source changed during no-clobber move"
        end
      end

      native_unlinkat(parent.fileno, basename)
    rescue Errno::ENOENT
      # A concurrent cleanup already removed the exact verified source. The
      # destination remains a complete, fsynced publication.
      nil
    end

    def cleanup_interrupted_copy(parent, token)
      lock_basename = ".shelfarr-copy-#{token}.lock"
      temporary_basename = ".shelfarr-copy-#{token}.tmp"

      with_pinned_regular_child(parent, lock_basename) do |lock|
        return unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        return unless lock.stat.uid == Process.euid

        lock_identity = file_identity(lock.stat)
        lock.rewind
        state, expected_temporary_identity, destination_basename,
          expected_destination_identity = copy_lock_cleanup_state(lock.read, token)
        cleanup_result = case state
        when :full
          remove_pinned_child_if_identity(
            parent,
            temporary_basename,
            expected_temporary_identity
          )
        when :compatibility_copying
          destination_cleanup = remove_pinned_child_if_identity(
            parent,
            destination_basename,
            expected_destination_identity
          )
          if destination_cleanup.in?([ :removed, :missing ])
            remove_pinned_child_if_identity(
              parent,
              temporary_basename,
              expected_temporary_identity
            )
          else
            destination_cleanup
          end
        when :compatibility_prepared
          # The process exited before recording the final inode. Never remove
          # an occupied path that cannot be proven to belong to this attempt.
          if pinned_child_missing?(parent, destination_basename)
            remove_pinned_child_if_identity(
              parent,
              temporary_basename,
              expected_temporary_identity
            )
          else
            :retained
          end
        when :compatibility_complete
          destination_status = begin
            pinned_child_identity(parent, destination_basename) == expected_destination_identity ?
              :complete : :retained
          rescue Errno::ENOENT
            :missing
          rescue Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
            :retained
          end
          if destination_status.in?([ :complete, :missing ])
            remove_pinned_child_if_identity(
              parent,
              temporary_basename,
              expected_temporary_identity
            )
          else
            destination_status
          end
        when :pending, :legacy
          remove_pinned_regular_child(parent, temporary_basename)
        else
          pinned_child_missing?(parent, temporary_basename) ? :missing : :retained
        end
        return unless cleanup_result.in?([ :removed, :missing ])

        remove_pinned_child_if_identity(parent, lock_basename, lock_identity)
        sync_io(parent)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::EWOULDBLOCK, IOError
      nil
    end

    def cleanup_interrupted_quarantine(parent, basename, expected_identity)
      quarantine = open_pinned_directory_child(parent, basename)
      begin
        stat = quarantine.stat
        return unless stat.uid == Process.euid && (stat.mode & 0o777) == 0o700

        quarantine_identity = file_identity(stat)
        children = pinned_directory_children(quarantine)
        if children.empty?
          return if stat.mtime > Time.now - COPY_QUARANTINE_STALE_AGE

          remove_empty_cleanup_quarantine!(
            parent,
            basename,
            quarantine,
            quarantine_identity
          )
          return
        end
        return unless children == [ COPY_QUARANTINE_ENTRY ]

        with_pinned_regular_child(quarantine, COPY_QUARANTINE_ENTRY) do |entry|
          return unless file_identity(entry.stat) == expected_identity

          native_unlinkat(quarantine.fileno, COPY_QUARANTINE_ENTRY)
        end
        sync_io(quarantine)

        remove_empty_cleanup_quarantine!(
          parent,
          basename,
          quarantine,
          quarantine_identity
        )
      ensure
        quarantine.close unless quarantine.closed?
      end
    rescue Errno::ENOENT, Errno::ELOOP, UnsafePathError
      nil
    end

    def persist_copy_lock_pending!(lock, token)
      persist_copy_lock_record!(lock, "#{COPY_LOCK_MAGIC}:#{token}:pending")
    end

    def persist_copy_lock_identity!(lock, token, identity)
      persist_copy_lock_record!(
        lock,
        "#{COPY_LOCK_MAGIC}:#{token}:full:#{identity.first}:#{identity.last}"
      )
    end

    def persist_copy_lock_compatibility!(
      lock,
      token,
      state,
      temporary_identity,
      destination_basename,
      destination_identity = nil
    )
      encoded_basename = destination_basename.b.unpack1("H*")
      record = "#{COPY_LOCK_MAGIC}:#{token}:compatibility:#{state}:" \
        "#{temporary_identity.first}:#{temporary_identity.last}:"
      if destination_identity
        record << "#{destination_identity.first}:#{destination_identity.last}:"
      end
      record << encoded_basename

      checksum = Digest::SHA256.hexdigest(record)
      lock.seek(0, IO::SEEK_END)
      lock.write("\n#{record}:#{checksum}\n")
      flush_and_sync(lock)
    end

    def persist_copy_lock_record!(lock, record)
      lock.rewind
      lock.truncate(0)
      lock.write(record)
      flush_and_sync(lock)
    end

    def copy_lock_cleanup_state(contents, token)
      contents.lines(chomp: true).reverse_each do |record|
        if record.start_with?("#{COPY_LOCK_MAGIC}:#{token}:compatibility:")
          journal_record, separator, checksum = record.rpartition(":")
          next if separator.empty? || checksum.length != 64 ||
            Digest::SHA256.hexdigest(journal_record) != checksum

          record = journal_record
        end

        state = copy_lock_record_cleanup_state(record, token)
        return state unless state.first == :malformed
      end
      [ :malformed, nil ]
    end

    def copy_lock_record_cleanup_state(contents, token)
      if (record = COPY_LOCK_COMPATIBILITY_PATTERN.match(contents)) && record[1] == token
        encoded_basename = record[7]
        return [ :malformed, nil, nil, nil ] unless encoded_basename.length.even? &&
          encoded_basename.length <= 510

        destination_basename = [ encoded_basename ].pack("H*")
        return [ :malformed, nil, nil, nil ] if destination_basename.empty? ||
          destination_basename.include?(File::SEPARATOR) ||
          destination_basename.include?("\0") ||
          destination_basename.in?([ ".", ".." ])

        [
          record[2] == "complete" ? :compatibility_complete : :compatibility_copying,
          [ record[3].to_i, record[4].to_i ],
          destination_basename,
          [ record[5].to_i, record[6].to_i ]
        ]
      elsif (record = COPY_LOCK_COMPATIBILITY_PREPARED_PATTERN.match(contents)) && record[1] == token
        encoded_basename = record[4]
        return [ :malformed, nil, nil, nil ] unless encoded_basename.length.even? &&
          encoded_basename.length <= 510

        destination_basename = [ encoded_basename ].pack("H*")
        return [ :malformed, nil, nil, nil ] if destination_basename.empty? ||
          destination_basename.include?(File::SEPARATOR) ||
          destination_basename.include?("\0") ||
          destination_basename.in?([ ".", ".." ])

        [
          :compatibility_prepared,
          [ record[2].to_i, record[3].to_i ],
          destination_basename,
          nil
        ]
      elsif (record = COPY_LOCK_RECORD_PATTERN.match(contents)) && record[1] == token
        [ :full, [ record[2].to_i, record[3].to_i ] ]
      elsif (record = COPY_LOCK_PENDING_PATTERN.match(contents)) && record[1] == token
        [ :pending, nil ]
      elsif (record = COPY_LOCK_LEGACY_PATTERN.match(contents)) && record[1] == token
        [ :legacy, nil ]
      else
        [ :malformed, nil ]
      end
    end

    def pinned_child_missing?(parent, basename)
      descriptor = native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
        0
      )
      child = IO.new(descriptor, "rb", autoclose: true)
      child.close
      false
    rescue Errno::ENOENT
      true
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
      false
    end

    def compare_io(left, right)
      left_buffer = +""
      right_buffer = +""
      loop do
        left_bytes = left.read(BUFFER_SIZE, left_buffer)
        right_bytes = right.read(BUFFER_SIZE, right_buffer)
        return true unless left_bytes || right_bytes
        return false unless left_bytes == right_bytes
      end
    end

    def with_pinned_source(path, source_root: nil)
      expanded = Pathname(path).expand_path
      return with_pinned_source_root(expanded, source_root) { |*values| yield(*values) } if source_root

      canonical_parent = expanded.parent.realpath
      with_pinned_absolute_directory(canonical_parent) do |parent|
        validate_current_directory_identity!(expanded.parent, parent)
        with_pinned_regular_child(parent, expanded.basename.to_s) do |source|
          yield source, parent, expanded.basename.to_s, expanded.parent
        end
      end
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "source path contains a symbolic link or non-directory: #{error.message}"
    end

    def with_pinned_hardlink_source(path, source_root:)
      expanded = Pathname(path).expand_path
      if source_root
        return with_pinned_hardlink_source_root(expanded, source_root) { |*values| yield(*values) }
      end

      canonical_parent = expanded.parent.realpath
      with_pinned_absolute_directory(canonical_parent) do |parent|
        validate_current_directory_identity!(expanded.parent, parent)
        with_pinned_regular_child(parent, expanded.basename.to_s) do |source|
          manifest = file_manifest_entry(source.stat)
          result = yield source, parent, expanded.basename.to_s, expanded.parent, manifest
          unless stable_hardlink_manifest_entry(source.stat) == stable_hardlink_snapshot_entry(manifest)
            raise Errno::ESTALE, "source file changed while it was being hardlinked"
          end
          result
        end
      end
    rescue Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "source path contains a symbolic link or non-directory: #{error.message}"
    end

    def with_pinned_hardlink_source_root(expanded, source_root)
      relative = expanded.relative_path_from(source_root.path)
      if relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}") || relative.to_s == "."
        raise UnsafePathError, "source file is outside the snapshotted download tree"
      end

      with_pinned_absolute_directory(source_root.canonical_path) do |root|
        unless file_identity(root.stat) == [ source_root.device, source_root.inode ]
          raise Errno::ESTALE, "source root identity changed during import"
        end
        validate_current_directory_identity!(source_root.path, root)

        with_pinned_relative_directory(root, relative.dirname, create: false) do |parent|
          parent_path = source_root.path.join(relative.dirname)
          validate_current_directory_identity!(parent_path, parent)
          expected_parent = if relative.dirname.to_s == "."
            [ source_root.device, source_root.inode, :directory ]
          else
            source_root.entries[relative.dirname.to_s]
          end
          unless expected_parent && expected_parent.first(2) == file_identity(parent.stat) &&
              expected_parent[2] == :directory
            raise Errno::ESTALE, "source directory changed after it was snapshotted"
          end

          with_pinned_regular_child(parent, relative.basename.to_s) do |source|
            expected_source = source_root.entries[relative.to_s]
            unless expected_source &&
                stable_hardlink_snapshot_entry(expected_source) == stable_hardlink_manifest_entry(source.stat)
              raise Errno::ESTALE, "source file changed after it was snapshotted"
            end
            result = yield source, parent, relative.basename.to_s, parent_path, expected_source
            unless stable_hardlink_manifest_entry(source.stat) == stable_hardlink_snapshot_entry(expected_source)
              raise Errno::ESTALE, "source file changed while it was being hardlinked"
            end
            result
          end
        end
      end
    rescue ArgumentError, Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "source path contains a symbolic link or non-directory: #{error.message}"
    end

    def with_pinned_source_root(expanded, source_root)
      relative = expanded.relative_path_from(source_root.path)
      if relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}") || relative.to_s == "."
        raise UnsafePathError, "source file is outside the snapshotted download tree"
      end

      with_pinned_absolute_directory(source_root.canonical_path) do |root|
        unless file_identity(root.stat) == [ source_root.device, source_root.inode ]
          raise Errno::ESTALE, "source root identity changed during import"
        end
        validate_current_directory_identity!(source_root.path, root)

        with_pinned_relative_directory(root, relative.dirname, create: false) do |parent|
          parent_path = source_root.path.join(relative.dirname)
          validate_current_directory_identity!(parent_path, parent)
          expected_parent = if relative.dirname.to_s == "."
            [ source_root.device, source_root.inode, :directory ]
          else
            source_root.entries[relative.dirname.to_s]
          end
          unless expected_parent && expected_parent.first(2) == file_identity(parent.stat) &&
              expected_parent[2] == :directory
            raise Errno::ESTALE, "source directory changed after it was snapshotted"
          end
          with_pinned_regular_child(parent, relative.basename.to_s) do |source|
            expected_source = source_root.entries[relative.to_s]
            unless expected_source == file_manifest_entry(source.stat)
              raise Errno::ESTALE, "source file changed after it was snapshotted"
            end
            result = yield source, parent, relative.basename.to_s, parent_path
            unless expected_source == file_manifest_entry(source.stat)
              raise Errno::ESTALE, "source file changed while it was being imported"
            end
            result
          end
        end
      end
    rescue ArgumentError, Errno::ELOOP, Errno::ENOTDIR => error
      raise UnsafePathError, "source path contains a symbolic link or non-directory: #{error.message}"
    end

    def snapshot_pinned_regular_tree(
      directory,
      prefix = nil,
      manifest = {},
      heartbeat: nil,
      max_entries: nil,
      max_depth: nil,
      depth: 0
    )
      remaining = max_entries && max_entries - manifest.size
      pinned_directory_children(directory, max_entries: remaining).each do |entry|
        heartbeat&.call
        descriptor = native_openat(
          directory.fileno,
          entry,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
          0
        )
        child = IO.new(descriptor, "rb", autoclose: true)
        begin
          stat = child.stat
          relative = prefix ? prefix.join(entry) : Pathname(entry)
          if stat.directory?
            if max_depth && depth + 1 > max_depth
              raise UnsafePathError, "source tree nesting is too deep"
            end

            manifest[relative.to_s] = directory_manifest_entry(stat)
            snapshot_pinned_regular_tree(
              child,
              relative,
              manifest,
              heartbeat: heartbeat,
              max_entries: max_entries,
              max_depth: max_depth,
              depth: depth + 1
            )
          elsif stat.file?
            manifest[relative.to_s] = file_manifest_entry(stat)
          else
            raise UnsafePathError, "source tree contains a symbolic link or non-regular path"
          end
        ensure
          child.close unless child.closed?
        end
      end
      manifest
    end

    def secure_pinned_library_tree!(directory, heartbeat: nil)
      pinned_directory_children(directory).each do |entry|
        heartbeat&.call
        descriptor = native_openat(
          directory.fileno,
          entry,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
          0
        )
        child = IO.new(descriptor, "rb", autoclose: true)
        begin
          stat = child.stat
          if stat.directory?
            secure_pinned_library_tree!(child, heartbeat: heartbeat)
            native_fchmod(child.fileno, DIRECTORY_MODE)
          elsif stat.file?
            native_fchmod(child.fileno, LIBRARY_FILE_MODE)
          else
            raise UnsafePathError, "source tree contains a symbolic link or non-regular path"
          end
          sync_io(child)
        ensure
          child.close unless child.closed?
        end
      end
      native_fchmod(directory.fileno, DIRECTORY_MODE)
      sync_io(directory)
    end

    def digest_pinned_regular_tree(directory, prefix = nil, manifest:, heartbeat: nil)
      pinned_directory_children(directory).each do |entry|
        heartbeat&.call
        descriptor = native_openat(
          directory.fileno,
          entry,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
          0
        )
        child = IO.new(descriptor, "rb", autoclose: true)
        begin
          relative = prefix ? prefix.join(entry) : Pathname(entry)
          stat = child.stat
          if stat.directory?
            manifest[relative.to_s] = [ "directory" ]
            digest_pinned_regular_tree(child, relative, manifest: manifest, heartbeat: heartbeat)
          elsif stat.file?
            digest = Digest::SHA256.new
            buffer = +""
            while child.read(BUFFER_SIZE, buffer)
              digest << buffer
              heartbeat&.call
            end
            manifest[relative.to_s] = [ "file", stat.size, digest.hexdigest ]
          else
            raise UnsafePathError, "source tree contains a symbolic link or non-regular path"
          end
        ensure
          child.close unless child.closed?
        end
      end
      manifest
    end

    def remove_pinned_tree_contents!(directory, expected_entries, prefix = nil)
      children = pinned_directory_children(directory)
      expected_children = expected_entries.keys.filter_map do |relative|
        path = Pathname(relative)
        next unless path.dirname == (prefix || Pathname("."))

        path.basename.to_s
      end.sort
      unless children == expected_children
        raise Errno::ESTALE, "quarantined source tree changed during cleanup"
      end

      children.each do |entry|
        relative = prefix ? prefix.join(entry) : Pathname(entry)
        expected = expected_entries.fetch(relative.to_s)
        quarantine = ".shelfarr-remove-child-#{SecureRandom.hex(16)}"
        renamed = native_rename_noreplace(
          directory.fileno,
          entry,
          directory.fileno,
          quarantine
        )
        raise Errno::ESTALE, "source child changed during cleanup" unless renamed

        descriptor = native_openat(
          directory.fileno,
          quarantine,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
          0
        )
        child = IO.new(descriptor, "rb", autoclose: true)
        begin
          stat = child.stat
          if expected[2] == :directory
            unless stat.directory? && file_identity(stat) == expected.first(2)
              restore_quarantined_replacement(directory, quarantine, entry)
              raise Errno::ESTALE, "source directory changed during cleanup"
            end
            remove_pinned_tree_contents!(child, expected_entries, relative)
            unless pinned_child_identity(directory, quarantine, directory: true) == expected.first(2)
              restore_quarantined_replacement(directory, quarantine, entry)
              raise Errno::ESTALE, "source directory changed during cleanup"
            end
            native_unlinkat(directory.fileno, quarantine, AT_REMOVEDIR)
          else
            current = file_manifest_entry(stat)
            unless stat.file? && current.first(5) == expected.first(5)
              restore_quarantined_replacement(directory, quarantine, entry)
              raise Errno::ESTALE, "source file changed during cleanup"
            end
            unless pinned_child_identity(directory, quarantine) == expected.first(2)
              restore_quarantined_replacement(directory, quarantine, entry)
              raise Errno::ESTALE, "source file changed during cleanup"
            end
            native_unlinkat(directory.fileno, quarantine)
          end
          sync_io(directory)
        ensure
          child.close unless child.closed?
        end
      end
    end

    def pinned_directory_children(directory, max_entries: nil)
      duplicate = directory.dup
      listing = Dir.for_fd(duplicate.fileno)
      duplicate.autoclose = false
      children = []
      listing.each_child do |entry|
        if max_entries && children.length >= max_entries
          raise UnsafePathError, "source tree contains too many entries"
        end

        children << utf8_directory_entry(entry)
      end
      children.sort
    ensure
      listing&.close
      duplicate&.close unless duplicate&.closed?
    end

    def utf8_directory_entry(entry)
      # Dir.for_fd has no path or encoding argument, so Ruby returns raw
      # filename bytes as ASCII-8BIT. Shelfarr paths and metadata are UTF-8;
      # retag valid bytes without transcoding or changing syscall identity.
      name = entry.dup.force_encoding(Encoding::UTF_8)
      return name if name.valid_encoding?

      raise UnsafePathError, "source tree contains a filename that is not valid UTF-8"
    end

    def directory_manifest_entry(stat)
      [ stat.dev, stat.ino, :directory, stat.size, stat.mtime.to_r, stat.ctime.to_r ]
    end

    def file_manifest_entry(stat)
      [ stat.dev, stat.ino, :file, stat.size, stat.mtime.to_r, stat.ctime.to_r, stat.mode & 0o7777 ]
    end

    def stable_hardlink_manifest_entry(stat)
      [ stat.dev, stat.ino, :file, stat.size, stat.mtime.to_r, stat.mode & 0o7777 ]
    end

    def stable_hardlink_snapshot_entry(manifest)
      [ *manifest.first(5), manifest.fetch(6) ]
    end

    def pinned_child_identity(parent, basename, directory: false)
      descriptor = native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
        0
      )
      child = IO.new(descriptor, "rb", autoclose: true)
      begin
        stat = child.stat
        expected_type = directory ? stat.directory? : stat.file?
        raise UnsafePathError, "quarantined source changed type" unless expected_type

        file_identity(stat)
      ensure
        child.close unless child.closed?
      end
    end

    def restore_quarantined_replacement(parent, quarantine_basename, original_basename)
      restored = native_rename_noreplace(
        parent.fileno,
        quarantine_basename,
        parent.fileno,
        original_basename
      )
      return if restored

      raise UnsafePathError,
        "a replacement download directory was retained in quarantine for manual review"
    rescue Errno::EEXIST
      raise UnsafePathError,
        "a replacement download directory was retained in quarantine for manual review"
    end

    def with_pinned_destination_parent(destination, root:)
      destination = Pathname(destination).expand_path
      expanded_root, canonical_root, relative = destination_root_and_relative(destination, root)
      parent_relative = relative.dirname

      with_pinned_absolute_directory(canonical_root) do |root_directory|
        validate_current_directory_identity!(expanded_root, root_directory)
        with_pinned_relative_directory(root_directory, parent_relative, create: false) do |parent|
          yield parent, destination.basename.to_s, destination.parent
        end
      end
    end

    def with_pinned_directory(path, root:, create:, mode:)
      path = Pathname(path).expand_path
      expanded_root, canonical_root, relative = destination_root_and_relative(path, root)

      with_pinned_absolute_directory(canonical_root) do |root_directory|
        validate_current_directory_identity!(expanded_root, root_directory)
        with_pinned_relative_directory(root_directory, relative, create: create, mode: mode) do |directory|
          validate_current_directory_identity!(path, directory)
          yield directory
        end
      end
    end

    def destination_root_and_relative(destination, root)
      expanded_root = Pathname(root.presence || destination.parent).expand_path
      canonical_root = expanded_root.realpath
      relative = destination.relative_path_from(expanded_root)
      if relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}")
        raise UnsafePathError, "destination is outside the configured library root"
      end

      [ expanded_root, canonical_root, relative ]
    rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
      raise UnsafePathError, "destination root is not safely accessible: #{error.message}"
    end

    def with_pinned_absolute_directory(path)
      path = Pathname(path).expand_path
      handles = []
      root = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      handles << root
      current = root
      path.each_filename do |part|
        next if part == File::SEPARATOR || part == "."
        raise UnsafePathError, "parent traversal is not allowed" if part == ".."

        current = open_pinned_directory_child(current, part)
        handles << current
      end
      yield current
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    def with_pinned_relative_directory(root, relative, create:, mode: DIRECTORY_MODE)
      handles = []
      current = root
      relative.each_filename do |part|
        next if part == "."
        raise UnsafePathError, "parent traversal is not allowed" if part == ".."

        begin
          child = open_pinned_directory_child(current, part)
        rescue Errno::ENOENT
          raise unless create

          begin
            native_mkdirat(current.fileno, part, mode)
          rescue Errno::EEXIST
            nil
          end
          child = open_pinned_directory_child(current, part)
          native_fchmod(child.fileno, mode)
          sync_io(current)
        end
        handles << child
        current = child
      end
      yield current
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    def open_pinned_directory_child(parent, basename)
      descriptor = native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
        0
      )
      directory = IO.new(descriptor, "rb", autoclose: true)
      unless directory.stat.directory?
        directory.close
        raise UnsafePathError, "destination contains a symbolic link or non-directory component"
      end
      directory
    end

    def with_pinned_regular_child(parent, basename)
      descriptor = native_openat(
        parent.fileno,
        basename,
        File::RDONLY | File::NOFOLLOW | File::NONBLOCK,
        0
      )
      file = File.for_fd(descriptor, "rb", autoclose: true)
      begin
        raise UnsafePathError, "path is not a regular file" unless file.stat.file?

        yield file
      ensure
        file.close unless file.closed?
      end
    end

    def with_created_regular_child(parent, basename, mode)
      descriptor = native_openat(
        parent.fileno,
        basename,
        File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW,
        mode
      )
      file = File.for_fd(descriptor, "r+b", autoclose: true)
      begin
        raise UnsafePathError, "created path is not a regular file" unless file.stat.file?

        yield file
      ensure
        file.close unless file.closed?
      end
    end

    def validate_current_directory_identity!(path, pinned_directory)
      current = File.lstat(Pathname(path).realpath)
      unless current.directory? && same_stat_identity?(current, pinned_directory.stat)
        raise Errno::ESTALE, "destination directory changed during publication"
      end
      true
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Errno::ESTALE, "destination directory changed during publication"
    end

    def remove_pinned_child_if_identity(parent, basename, expected_identity)
      return :mismatch unless expected_identity

      begin
        with_pinned_regular_child(parent, basename) do |child|
          return :mismatch unless file_identity(child.stat) == expected_identity
        end
      rescue Errno::ENOENT
        return :missing
      rescue Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
        return :retained
      end

      quarantine, quarantine_basename, quarantine_identity = create_cleanup_quarantine(
        parent,
        expected_identity
      )
      moved = false
      begin
        native_renameat(
          parent.fileno,
          basename,
          quarantine.fileno,
          COPY_QUARANTINE_ENTRY
        )
        moved = true
        sync_io(quarantine)
        sync_io(parent)

        quarantined_identity = nil
        result = begin
          removal_result = with_pinned_regular_child(quarantine, COPY_QUARANTINE_ENTRY) do |child|
            quarantined_identity = file_identity(child.stat)
            if quarantined_identity == expected_identity
              native_unlinkat(quarantine.fileno, COPY_QUARANTINE_ENTRY)
              :removed
            end
          end
          removal_result || :retained
        rescue Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
          :retained
        end
        if quarantined_identity && quarantined_identity != expected_identity
          restore_quarantined_child!(quarantine, parent, basename)
          result = :mismatch
        end
        sync_io(quarantine)
        remove_empty_cleanup_quarantine!(
          parent,
          quarantine_basename,
          quarantine,
          quarantine_identity
        )
        result
      rescue Errno::ENOENT
        moved ? :retained : :missing
      ensure
        unless moved
          remove_empty_cleanup_quarantine!(
            parent,
            quarantine_basename,
            quarantine,
            quarantine_identity
          )
        end
        quarantine.close unless quarantine.closed?
      end
    rescue Errno::ENOENT
      :missing
    end

    def remove_pinned_regular_child(parent, basename)
      identity = nil
      with_pinned_regular_child(parent, basename) do |child|
        identity = file_identity(child.stat)
      end
      remove_pinned_child_if_identity(parent, basename, identity)
    rescue Errno::ENOENT
      :missing
    rescue Errno::ELOOP, Errno::ENOTDIR, UnsafePathError
      :retained
    end

    def create_cleanup_quarantine(parent, expected_identity)
      loop do
        basename = ".shelfarr-copy-quarantine-#{expected_identity.first.to_s(16)}-" \
          "#{expected_identity.last.to_s(16)}-#{SecureRandom.hex(16)}"
        begin
          native_mkdirat(parent.fileno, basename, 0o700)
        rescue Errno::EEXIST
          next
        end

        quarantine = open_pinned_directory_child(parent, basename)
        begin
          stat = quarantine.stat
          unless stat.uid == Process.euid
            raise UnsafePathError, "cleanup quarantine is owned by another user"
          end

          native_fchmod(quarantine.fileno, 0o700)
          sync_io(quarantine)
          sync_io(parent)
          return [ quarantine, basename, file_identity(stat) ]
        rescue
          quarantine.close unless quarantine.closed?
          raise
        end
      end
    end

    def restore_quarantined_child!(quarantine, parent, basename)
      restored = native_rename_noreplace(
        quarantine.fileno,
        COPY_QUARANTINE_ENTRY,
        parent.fileno,
        basename
      )
      return if restored

      raise UnsafePathError, "mismatched cleanup entry was retained in quarantine"
    rescue Errno::EEXIST
      raise UnsafePathError, "mismatched cleanup entry was retained because its original path is occupied"
    end

    def remove_empty_cleanup_quarantine!(parent, basename, quarantine, expected_identity)
      return false unless pinned_directory_children(quarantine).empty?
      return false unless pinned_child_identity(parent, basename, directory: true) == expected_identity

      native_unlinkat(parent.fileno, basename, AT_REMOVEDIR)
      sync_io(parent)
      true
    rescue Errno::ENOENT, UnsafePathError
      false
    end

    def native_openat(directory_fd, basename, flags, mode)
      Fiddle.last_error = 0
      descriptor = if (flags & File::CREAT).positive?
        # openat is variadic when O_CREAT is present. On arm64 Darwin, treating
        # mode_t as a fixed fourth argument silently creates mode-000 files.
        function = native_function(
          :openat_create,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC ],
          symbol: :openat
        )
        function.call(directory_fd, basename, flags, Fiddle::TYPE_INT, mode)
      else
        function = native_function(
          :openat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
        )
        function.call(directory_fd, basename, flags)
      end
      return descriptor unless descriptor == -1

      raise SystemCallError.new("openat", Fiddle.last_error)
    end

    def native_mkdirat(directory_fd, basename, mode)
      call_native_function(
        native_function(:mkdirat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        mode
      )
    end

    def native_linkat(source_fd, source_basename, destination_fd, destination_basename)
      call_native_function(
        native_function(
          :linkat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
        ),
        source_fd,
        source_basename,
        destination_fd,
        destination_basename,
        0
      )
    end

    def native_unlinkat(directory_fd, basename, flags = 0)
      call_native_function(
        native_function(:unlinkat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        flags
      )
    end

    def native_fchmod(descriptor, mode)
      call_native_function(
        native_function(:fchmod, [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ]),
        descriptor,
        mode
      )
    end

    def native_futimes_now(descriptor)
      call_native_function(
        native_function(:futimes, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ]),
        descriptor,
        nil
      )
    end

    def native_renameat(source_fd, source_basename, destination_fd, destination_basename)
      call_native_function(
        native_function(
          :renameat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ]
        ),
        source_fd,
        source_basename,
        destination_fd,
        destination_basename
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

      signature = [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT ]
      call_native_function(native_function(function, signature), *arguments)
      true
    rescue Fiddle::DLError, Errno::ENOSYS, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
      false
    end

    def native_function(name, arguments, symbol: name)
      @native_functions ||= {}
      @native_functions[[ name, arguments ]] ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT[symbol.to_s],
        arguments,
        Fiddle::TYPE_INT
      )
    end

    def call_native_function(function, *arguments)
      Fiddle.last_error = 0
      result = function.call(*arguments)
      return result if result.zero?

      raise SystemCallError.new("filesystem operation", Fiddle.last_error)
    end

    def file_identity(stat)
      [ stat.dev, stat.ino ]
    end

    def flush_and_sync(io)
      io.flush
      io.fsync
    rescue Errno::EINVAL, Errno::EOPNOTSUPP
      nil
    end

    def sync_io(io)
      io.fsync
    rescue Errno::EINVAL, Errno::EOPNOTSUPP
      nil
    end

    def same_stat_identity?(left, right)
      left.dev == right.dev && left.ino == right.ino
    end

    def copy_file_range_error?(error)
      error.message.include?("copy_file_range")
    end

    def move_via_copy(src, dest)
      cp(src, dest)
      remove_source_safely(src, dest)
    end

    def remove_source_safely(src, dest)
      if File.directory?(src)
        FileUtils.rm_rf(src)
      else
        FileUtils.rm_f(src)
      end
    rescue => e
      if source_move_verified?(src, dest)
        Rails.logger.warn "[FileCopyService] Source removal failed after successful copy (non-fatal): #{e.message}"
      else
        raise
      end
    end

    def source_move_verified?(src, dest)
      dest_path = resolved_destination_path(src, dest)
      return false unless dest_path && File.exist?(dest_path)

      if File.directory?(src)
        File.directory?(dest_path)
      else
        File.file?(dest_path) && File.size(dest_path) == File.size(src)
      end
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def resolved_destination_path(src, dest)
      File.directory?(dest) ? File.join(dest, File.basename(src)) : dest
    end

    def buffered_copy(src, dest)
      dest = File.join(dest, File.basename(src)) if File.directory?(dest)

      File.open(src, "rb") do |source|
        File.open(dest, "wb") do |target|
          buf = +""
          target.write(buf) while source.read(BUFFER_SIZE, buf)
        end
      end

      stat = File.stat(src)
      FileUtils.chmod(stat.mode, dest)
      File.utime(stat.atime, stat.mtime, dest)
    end

    def buffered_copy_io(source, target)
      buffer = +""
      target.write(buffer) while source.read(BUFFER_SIZE, buffer)
    end

    def recursive_buffered_copy(src, dest)
      if File.directory?(src)
        dest_dir = File.directory?(dest) ? File.join(dest, File.basename(src)) : dest
        FileUtils.mkdir_p(dest_dir)
        FileUtils.chmod(File.stat(src).mode, dest_dir)

        (Dir.entries(src) - %w[. ..]).each do |entry|
          recursive_buffered_copy(File.join(src, entry), dest_dir)
        end
      else
        buffered_copy(src, dest)
      end
    end
  end
end
