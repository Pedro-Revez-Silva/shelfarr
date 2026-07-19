# frozen_string_literal: true

require "digest"
require "fiddle"
require "pathname"
require "securerandom"

# Crash-safe filesystem publication for ordinary, single-file uploads.
#
# A destination/root/template snapshot and content digest are persisted before
# publication. The large copy happens in a private directory on the target
# filesystem and outside SQLite transactions, then a hard link publishes the
# completed file atomically without replacing another writer's file. The
# original upload remains in place until the database records completion.
class UploadImportFileService
  class Error < StandardError; end
  class AmbiguousPublicationError < Error; end
  class IngressTooLargeError < Error; end

  PRIVATE_DIRECTORY = ".shelfarr-upload-staging"
  LOCKS_DIRECTORY = "locks"
  LOCK_SHARDS = 1_024
  FILE_MODE = 0o640
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  MAX_CANDIDATES = 10_000
  LINUX_RENAME_NOREPLACE = 0x1
  DARWIN_RENAME_EXCL = 0x4

  attr_reader :upload, :source_path

  class << self
    # Streams a browser upload into Shelfarr's private temp area through pinned
    # directory descriptors. The exclusive no-follow open prevents guessed
    # names or symlinks from truncating another file, while the runtime counter
    # does not trust the multipart size reported by the client.
    def stage_ingress!(source, basename, max_bytes:)
      root = Pathname(Rails.root.join("tmp")).expand_path
      FileUtils.mkdir_p(root, mode: 0o700)
      relative_directory = Pathname("uploads")
      destination = root.join(relative_directory, basename)
      published = false
      created = false
      size = 0
      identity = nil

      with_pinned_absolute_directory(root.realpath) do |root_directory|
        with_pinned_relative_directory(
          root_directory,
          relative_directory,
          create: true,
          mode: 0o700
        ) do |upload_directory|
          root_directory.fsync
          descriptor = native_openat(
            upload_directory.fileno,
            basename,
            flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
            mode: 0o600
          )
          created = true
          file = IO.new(descriptor, "wb", autoclose: true)
          begin
            source.rewind if source.respond_to?(:rewind)
            while (chunk = source.read(FileCopyService::BUFFER_SIZE))
              size += chunk.bytesize
              if size > max_bytes
                raise IngressTooLargeError,
                  "Upload exceeds Shelfarr's #{ActiveSupport::NumberHelper.number_to_human_size(max_bytes)} limit"
              end
              file.write(chunk)
            end
            file.flush
            file.fsync
            native_fchmod(file.fileno, 0o600)
            identity = [ file.stat.dev, file.stat.ino ]
          ensure
            file.close unless file.closed?
          end
          upload_directory.fsync

          # Prove the returned pathname still reaches the exact file written
          # through the pinned directory before it is persisted in SQLite.
          with_pinned_absolute_directory(destination.parent) do |current_directory|
            unless same_file_identity?(current_directory.stat, upload_directory.stat)
              raise Error, "Shelfarr's private upload directory changed during staging"
            end
            with_pinned_child(current_directory, basename) do |current_file|
              unless [ current_file.stat.dev, current_file.stat.ino ] == identity
                raise Error, "Shelfarr's private upload file changed during staging"
              end
            end
          end
          published = true
        ensure
          if created && !published
            native_unlinkat(upload_directory.fileno, basename) if upload_directory
            upload_directory&.fsync
          end
        end
      end

      [ destination.to_s, size ]
    rescue IngressTooLargeError
      raise
    rescue Errno::EEXIST
      raise Error, "Shelfarr refused to replace an existing private upload file"
    rescue SystemCallError => error
      raise Error, "Shelfarr could not stage the upload safely: #{error.message}"
    end

    # Removes only files which are still inside Shelfarr's private browser
    # ingress directory. Upload rows can outlive configuration changes and may
    # eventually point at durable staging or library paths; model cleanup must
    # never turn such a persisted pathname into an unrestricted unlink.
    def discard_ingress!(raw_path)
      return false if raw_path.blank?

      root = Pathname(Rails.root.join("tmp")).expand_path
      upload_directory_path = root.join("uploads")
      candidate = Pathname(raw_path).expand_path
      return false unless candidate.parent == upload_directory_path

      removed = false
      with_pinned_absolute_directory(root.realpath) do |root_directory|
        with_pinned_relative_directory(
          root_directory,
          Pathname("uploads"),
          create: false,
          mode: 0o700
        ) do |upload_directory|
          with_pinned_child(upload_directory, candidate.basename.to_s) do |file|
            identity = file.stat
            quarantine = ".shelfarr-discard-#{SecureRandom.hex(16)}"
            renamed = native_rename_noreplace(
              upload_directory.fileno,
              candidate.basename.to_s,
              upload_directory.fileno,
              quarantine
            )
            unless renamed
              raise Error, "The upload filesystem cannot quarantine ingress cleanup atomically"
            end

            upload_directory.fsync
            unless pinned_child_matches?(upload_directory, quarantine, identity)
              restore_ingress_quarantine(
                upload_directory,
                quarantine,
                candidate.basename.to_s
              )
              raise Error, "The private upload file changed before cleanup"
            end

            native_unlinkat(upload_directory.fileno, quarantine)
            upload_directory.fsync
            removed = true
          end
        end
      end
      removed
    rescue Errno::ENOENT
      true
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, Error => error
      Rails.logger.warn(
        "[UploadImportFileService] Refused unsafe ingress cleanup: #{error.class}"
      )
      false
    end

    def recoverable_file?(upload)
      !archive_upload?(upload)
    end

    def archive_upload?(upload)
      upload.audiobook_file? && File.extname(upload.original_filename).casecmp?(".zip")
    end

    def recovery_source_path(upload)
      source = Pathname(upload.cleanup_source_path.presence || upload.file_path.to_s).expand_path
      digest = upload.content_sha256.to_s
      return source.to_s if valid_regular_file?(source, upload.file_size, digest: digest.presence)

      return unless complete_reservation?(upload)

      destination = validated_reserved_destination(upload, require_parent: true)
      return destination.to_s if valid_regular_file?(destination, upload.file_size, digest: digest)

      raise Error, "Both the uploaded file and its reserved library copy are missing or changed"
    end

    def restore_and_clear!(upload)
      return true unless upload.destination_path.present?
      return false unless complete_reservation?(upload)

      root = validated_reserved_root(upload)
      library_path = Pathname(upload.library_path.to_s).expand_path
      OwnedMediaImportFileService.with_lock(root, "destination-#{library_path}") do
        with_lock(root, "upload-#{upload.id}") do
          upload.reload
          return true if upload.completed?

          source = Pathname(upload.cleanup_source_path.presence || upload.file_path.to_s).expand_path
          destination = validated_reserved_destination(upload, require_parent: false)
          digest = upload.content_sha256.to_s
          source_valid = valid_regular_file?(source, upload.file_size, digest: digest)
          destination_exists = path_occupied?(destination)
          validate_existing_parent_chain!(destination.parent, root) if destination_exists
          destination_valid = valid_regular_file?(
            destination,
            upload.file_size,
            digest: digest
          )

          if destination_valid && source_valid
            configured_root = validated_configured_root(upload)
            display_path = configured_root.join(destination.relative_path_from(root)).to_s
            display_library_path = configured_root.join(library_path.relative_path_from(root)).to_s
            adopted = Book.acquired.where(
              file_path: [
                destination.to_s,
                display_path,
                library_path.to_s,
                display_library_path
              ].uniq
            ).exists?
            return false if adopted

            remove_verified_destination!(
              destination,
              expected_size: upload.file_size,
              digest: digest
            )
          elsif destination_valid
            # The published copy may now be the only survivor. Retain its exact
            # reservation for an idempotent retry instead of deleting it.
            return false
          elsif destination_exists && !source_valid
            # Never remove or forget an unexpected path when it is the only
            # possible surviving copy. Keeping the reservation prevents another
            # upload from adopting this destination silently.
            return false
          elsif !source_valid
            return false
          end

          remove_private_copy(upload, root)
          clear_reservation!(upload)
          remove_empty_library_directories(library_path, destination, root)
          true
        end
      end
    rescue Error, SystemCallError => error
      Rails.logger.error(
        "[UploadImportFileService] Could not restore upload ##{upload.id}: " \
          "#{error.class}: #{error.message}"
      )
      false
    end

    def cleanup_completed_source!(upload)
      upload.reload
      return true if upload.cleanup_source_path.blank?
      return false unless upload.completed? && complete_reservation?(upload)

      destination = validated_reserved_destination(upload, require_parent: true)
      digest = upload.content_sha256.to_s
      return false unless valid_regular_file?(destination, upload.file_size, digest: digest)

      source = Pathname(upload.cleanup_source_path).expand_path
      if source == destination
        raise Error, "The upload cleanup path points at the library publication"
      end

      with_pinned_file(
        source,
        flags: File::RDWR | File::NOFOLLOW | File::NONBLOCK
      ) do |file, _parent|
        stat = file.stat
        raise Error, "The upload cleanup path is not a regular file" unless stat.file?

        unless stat.size.zero?
          validate_open_file!(file, upload.file_size, digest)
          native_ftruncate(file.fileno, 0)
          file.fsync
        end
      end
      Upload.where(id: upload.id, status: Upload.statuses[:completed])
        .update_all(cleanup_source_path: nil, updated_at: Time.current)
      upload.reload
      true
    rescue Errno::ENOENT
      Upload.where(id: upload.id, status: Upload.statuses[:completed])
        .update_all(cleanup_source_path: nil, updated_at: Time.current)
      upload.reload
      true
    end

    def complete_reservation?(upload)
      upload.destination_path.present? &&
        upload.destination_root.present? &&
        upload.destination_configured_root.present? &&
        upload.library_path.present? &&
        upload.content_sha256.to_s.match?(SHA256_PATTERN)
    end

    def with_lock(root, key)
      canonical_root = Pathname(root).realpath
      with_pinned_absolute_directory(canonical_root) do |root_directory|
        relative = Pathname(PRIVATE_DIRECTORY).join(database_fingerprint, LOCKS_DIRECTORY)
        with_pinned_relative_directory(root_directory, relative, create: true, mode: 0o700) do |locks|
          shard = Digest::SHA256.hexdigest(key.to_s).to_i(16) % LOCK_SHARDS
          descriptor = open_or_create_lock(locks, format("lock-%04d", shard))
          lock = File.for_fd(descriptor, "r+", autoclose: true)
          begin
            raise Error, "Upload recovery lock is not a regular file" unless lock.stat.file?
            native_fchmod(lock.fileno, 0o600)
            raise Error, "Upload recovery lock could not be acquired" unless lock.flock(File::LOCK_EX)

            yield
          ensure
            lock.close unless lock.closed?
          end
        end
      end
    rescue Errno::ELOOP, Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR => error
      raise Error, "Shelfarr could not lock the upload destination: #{error.message}"
    end

    # Resolve the longest existing configured prefix once, then create only the
    # missing suffix relative to a pinned descriptor. This accepts a stable,
    # intentional alias while preventing a writable ancestor from redirecting
    # creation through a raced symlink.
    def secure_configured_directory!(raw_path)
      configured = Pathname(raw_path).expand_path
      if configured.exist?
        canonical = configured.realpath
        FileCopyService.send(:with_pinned_absolute_directory, canonical) do |directory|
          unless directory.stat.directory?
            raise Error, "The configured upload output path is not a directory"
          end
          FileCopyService.send(:validate_current_directory_identity!, configured, directory)
        end
        return canonical
      end

      missing = []
      existing = configured
      until existing.exist?
        raise Error, "The configured upload output path has no existing parent" if existing.root?

        missing.unshift(existing.basename.to_s)
        existing = existing.parent
      end

      canonical_parent = existing.realpath
      canonical = canonical_parent.join(*missing)
      FileCopyService.send(:with_pinned_absolute_directory, canonical_parent) do |parent|
        FileCopyService.send(:validate_current_directory_identity!, existing, parent)
        FileCopyService.send(
          :with_pinned_relative_directory,
          parent,
          Pathname(missing.join(File::SEPARATOR)),
          create: true,
          mode: FileCopyService::DIRECTORY_MODE
        ) do |directory|
          FileCopyService.send(:validate_current_directory_identity!, configured, directory)
          directory.fsync
        end
      end
      canonical.realpath
    rescue FileCopyService::UnsafePathError, Errno::ENOENT, Errno::EACCES,
      Errno::ELOOP, Errno::ENOTDIR => error
      raise Error, "The configured upload output path is unsafe: #{error.message}"
    end

    private

    def open_or_create_lock(directory, basename)
      loop do
        begin
          return native_openat(
            directory.fileno,
            basename,
            flags: File::RDWR | File::NOFOLLOW | File::NONBLOCK
          )
        rescue Errno::ENOENT
          return native_openat(
          directory.fileno,
          basename,
          flags: File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW | File::NONBLOCK,
          mode: 0o600
        )
        end
      rescue Errno::EEXIST
        next
      end
    end

    def validated_reserved_root(upload)
      root = Pathname(upload.destination_root.to_s).expand_path
      resolved = root.realpath
      unless resolved.to_s == root.to_s
        raise Error, "The reserved upload root changed after it was planned"
      end

      resolved
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "The reserved upload root is not accessible"
    end

    def validated_configured_root(upload)
      configured = Pathname(upload.destination_configured_root.to_s).expand_path
      canonical = validated_reserved_root(upload)
      unless configured.realpath == canonical
        raise Error, "The configured upload root changed after it was planned"
      end

      configured
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "The configured upload root is not accessible"
    end

    def validated_reserved_destination(upload, require_parent:)
      root = validated_reserved_root(upload)
      destination = Pathname(upload.destination_path.to_s).expand_path
      library_path = Pathname(upload.library_path.to_s).expand_path
      validate_path_within_root!(destination, root)
      validate_path_within_root!(library_path, root)
      validate_existing_parent_chain!(destination.parent, root) if require_parent
      destination
    end

    def clear_reservation!(upload)
      Upload.where(id: upload.id, status: Upload.statuses.values_at("pending", "processing", "failed"))
        .update_all(
          destination_path: nil,
          destination_root: nil,
          destination_configured_root: nil,
          library_path: nil,
          content_sha256: nil,
          cleanup_source_path: nil,
          updated_at: Time.current
        )
      upload.reload
    end

    def remove_private_copy(upload, root)
      with_pinned_absolute_directory(root) do |root_directory|
        relative = Pathname(PRIVATE_DIRECTORY).join(database_fingerprint)
        with_pinned_relative_directory(root_directory, relative, create: true, mode: 0o700) do |private_dir|
          native_unlinkat(private_dir.fileno, "upload_#{upload.id}.tmp")
          private_dir.fsync
        end
      end
    end

    def remove_verified_destination!(destination, expected_size:, digest:)
      quarantine = ".shelfarr-upload-rollback-#{SecureRandom.hex(16)}"
      with_pinned_absolute_directory(destination.parent) do |parent|
        original_identity = nil
        with_pinned_child(parent, destination.basename.to_s) do |file|
          validate_open_file!(file, expected_size, digest)
          original_identity = file.stat
        end

        renamed = native_rename_noreplace(
          parent.fileno,
          destination.basename.to_s,
          parent.fileno,
          quarantine
        )
        unless renamed
          raise Error, "The library filesystem cannot quarantine a rolled-back upload atomically"
        end
        parent.fsync

        begin
          with_pinned_child(parent, quarantine) do |file|
            unless same_file_identity?(file.stat, original_identity)
              raise Error, "The rolled-back upload changed during quarantine"
            end
            validate_open_file!(file, expected_size, digest)
          end
        rescue
          restore_ingress_quarantine(parent, quarantine, destination.basename.to_s)
          raise
        end

        native_unlinkat(parent.fileno, quarantine)
        parent.fsync
      end
      true
    end

    def validate_existing_parent_chain!(parent, root)
      parent = Pathname(parent).expand_path
      validate_path_within_root!(parent, root)
      relative = parent.relative_path_from(root)
      current = root
      relative.each_filename do |part|
        current = current.join(part)
        stat = File.lstat(current)
        raise Error, "Reserved upload path contains a symbolic link" unless stat.directory?
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "The reserved upload destination is not accessible"
    end

    def validate_path_within_root!(path, root)
      expanded = Pathname(path).expand_path
      return if expanded.to_s.start_with?("#{root}#{File::SEPARATOR}")

      raise Error, "The reserved upload path is outside its snapshotted root"
    end

    def valid_regular_file?(path, expected_size, digest: nil)
      with_pinned_file(path) do |file, _parent|
        validate_open_file!(file, expected_size, digest)
        true
      end
    rescue Error, Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
      false
    end

    def validate_open_file!(file, expected_size, digest)
      stat = file.stat
      raise Error, "The upload path is not a regular file" unless stat.file?
      if expected_size.present? && stat.size != expected_size.to_i
        raise Error, "The upload file size changed"
      end
      if digest.present? && sha256_io(file) != digest
        raise Error, "The upload file content changed"
      end

      true
    end

    def database_fingerprint
      Digest::SHA256.hexdigest(
        ActiveRecord::Base.connection_db_config.database.to_s
      ).first(12)
    end

    def with_pinned_file(path, flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      path = Pathname(path).expand_path
      with_pinned_absolute_directory(path.parent) do |parent|
        with_pinned_child(parent, path.basename.to_s, flags: flags) do |file|
          yield file, parent
        end
      end
    end

    def with_pinned_absolute_directory(path)
      path = Pathname(path).expand_path
      handles = []
      root = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
      handles << root
      current = root
      path.each_filename do |part|
        next if part == File::SEPARATOR || part == "."

        current = open_pinned_directory_child(current, part)
        handles << current
      end
      yield current
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    def with_pinned_relative_directory(root, relative, create:, mode:)
      handles = []
      current = root
      Pathname(relative).each_filename do |part|
        next if part == "."
        raise Error, "Upload path escaped its pinned root" if part == ".."

        begin
          child = open_pinned_directory_child(current, part)
        rescue Errno::ENOENT
          raise unless create

          native_mkdirat(current.fileno, part, mode)
          child = open_pinned_directory_child(current, part)
        end
        native_fchmod(child.fileno, mode)
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
        flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
      directory = IO.new(descriptor, "rb", autoclose: true)
      unless directory.stat.directory?
        directory.close
        raise Error, "Upload path contains a symbolic link or non-directory component"
      end
      directory
    end

    def with_pinned_child(
      parent,
      basename,
      flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
      descriptor = native_openat(parent.fileno, basename, flags: flags)
      mode = (flags & File::RDWR).positive? ? "r+" : "rb"
      file = IO.new(descriptor, mode, autoclose: true)
      begin
        raise Error, "Upload path is not a regular file" unless file.stat.file?

        yield file
      ensure
        file.close unless file.closed?
      end
    end

    def pinned_child_matches?(parent, basename, expected_stat)
      with_pinned_child(parent, basename) do |child|
        return same_file_identity?(child.stat, expected_stat)
      end
    rescue Error, SystemCallError
      false
    end

    def native_linkat(source_directory_fd, source_basename, destination_directory_fd, destination_basename)
      call_native_path_function(
        native_function(
          :linkat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
        ),
        source_directory_fd,
        source_basename,
        destination_directory_fd,
        destination_basename,
        0
      )
    end

    def native_mkdirat(directory_fd, basename, mode)
      call_native_path_function(
        native_function(:mkdirat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        mode
      )
    rescue Errno::EEXIST
      nil
    end

    def native_openat(directory_fd, basename, flags: File::RDONLY | File::NOFOLLOW, mode: 0)
      function = native_function(
        :openat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT ]
      )
      Fiddle.last_error = 0
      descriptor = function.call(directory_fd, basename, flags, mode)
      return descriptor unless descriptor == -1

      raise SystemCallError.new("openat", Fiddle.last_error)
    end

    def native_unlinkat(directory_fd, basename)
      return if basename.blank?

      call_native_path_function(
        native_function(:unlinkat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        0
      )
    rescue Errno::ENOENT
      nil
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
      call_native_path_function(native_function(function, signature), *arguments)
      true
    rescue Fiddle::DLError, Errno::ENOSYS, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
      false
    end

    def restore_ingress_quarantine(directory, quarantine, original)
      restored = native_rename_noreplace(
        directory.fileno,
        quarantine,
        directory.fileno,
        original
      )
      directory.fsync if restored
      restored
    rescue SystemCallError
      # Never replace a concurrently restored ingress path. A retained private
      # quarantine is swept as an orphan after the normal grace period.
      false
    end

    def native_fchmod(descriptor, mode)
      call_native_path_function(
        native_function(:fchmod, [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ]),
        descriptor,
        mode
      )
    end

    def native_ftruncate(descriptor, length)
      call_native_path_function(
        native_function(:ftruncate, [ Fiddle::TYPE_INT, Fiddle::TYPE_LONG ]),
        descriptor,
        length
      )
    end

    def call_native_path_function(function, *arguments)
      Fiddle.last_error = 0
      result = function.call(*arguments)
      return result if result.zero?

      raise SystemCallError.new("filesystem operation", Fiddle.last_error)
    end

    def native_function(name, arguments)
      @native_functions ||= {}
      @native_functions[name] ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT[name.to_s],
        arguments,
        Fiddle::TYPE_INT
      )
    rescue Fiddle::DLError => error
      raise Error, "The library filesystem cannot safely pin upload paths: #{error.message}"
    end

    def sha256_io(io)
      digest = Digest::SHA256.new
      io.rewind
      buffer = +""
      digest.update(buffer) while io.read(1024 * 1024, buffer)
      digest.hexdigest
    end

    def path_occupied?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def same_file_identity?(left, right)
      left.dev == right.dev && left.ino == right.ino
    end

    def remove_empty_library_directories(library, destination, root)
      return if library == destination

      current = library
      while current != root && current.to_s.start_with?("#{root}#{File::SEPARATOR}")
        begin
          Dir.rmdir(current)
          current = current.parent
        rescue Errno::ENOENT, Errno::ENOTEMPTY
          break
        end
      end
    end
  end

  def initialize(upload:, book:)
    raise Error, "Archive uploads do not support crash-safe single-file publication" if self.class.archive_upload?(upload)

    @upload = upload
    @book = book
    @source_path = if upload.cleanup_source_path.present?
      Pathname(upload.cleanup_source_path).expand_path
    else
      source = Pathname(upload.file_path.to_s).expand_path
      source.parent.realpath.join(source.basename)
    end
    if upload.destination_root.present?
      @root = self.class.send(:validated_reserved_root, upload)
      @configured_root = self.class.send(:validated_configured_root, upload)
    else
      @configured_root, @root = configured_roots(book)
    end
    @flat_output = PathTemplateService.flat_output?(book)
    @planned_directory = Pathname(
      PathTemplateService.build_destination(book, base_path: @root.to_s)
    ).expand_path
    self.class.send(:validate_path_within_root!, @planned_directory, @root) unless @flat_output
    @planned_filename = PathTemplateService.build_filename(
      book,
      File.extname(upload.original_filename)
    )
  end

  def reserve!
    return validate_reservation! if upload.destination_path.present?

    digest, source_size = digest_source!
    _canonical_destination, canonical_library_path = candidate(1)
    OwnedMediaImportFileService.with_lock(
      @root,
      "destination-#{canonical_library_path}"
    ) do
      counter = 1
      loop do
        if counter > MAX_CANDIDATES
          raise Error, "Shelfarr could not find an available upload destination"
        end

        destination, library_path = candidate(counter)
        if occupied?(destination, library_path)
          counter += 1
          next
        end

        begin
          claimed = Upload.where(
            id: upload.id,
            status: Upload.statuses[:processing],
            destination_path: nil
          ).update_all(
            destination_path: destination.to_s,
            destination_root: @root.to_s,
            destination_configured_root: @configured_root.to_s,
            library_path: library_path.to_s,
            content_sha256: digest,
            cleanup_source_path: @source_path.to_s,
            file_size: source_size,
            updated_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique
          counter += 1
          next
        end

        upload.reload
        return validate_reservation! if claimed == 1 || upload.destination_path.present?

        raise Error, "The upload is no longer available for destination planning"
      end
    end
  end

  def publish!
    validate_reservation!
    root = self.class.send(:validated_reserved_root, upload)
    OwnedMediaImportFileService.with_lock(
      root,
      "destination-#{upload.library_path}"
    ) do
      self.class.with_lock(root, "upload-#{upload.id}") do
        upload.reload
        validate_reservation!
        destination = reserved_destination
        relative_parent = destination.parent.relative_path_from(root)
        private_relative = Pathname(PRIVATE_DIRECTORY).join(
          self.class.send(:database_fingerprint)
        )

        self.class.send(:with_pinned_absolute_directory, root) do |root_directory|
          self.class.send(
            :with_pinned_relative_directory,
            root_directory,
            relative_parent,
            create: true,
            mode: 0o750
          ) do |destination_parent|
            begin
              self.class.send(
                :with_pinned_child,
                destination_parent,
                destination.basename.to_s
              ) do |existing|
                self.class.send(
                  :validate_open_file!, existing, upload.file_size, upload.content_sha256
                )
                validate_published_parent!(destination.parent, destination_parent)
                self.class.send(:remove_private_copy, upload, root)
                return book_library_path
              end
            rescue Errno::ENOENT
              # Publish the verified private copy below.
            end

            self.class.send(
              :with_pinned_relative_directory,
              root_directory,
              private_relative,
              create: true,
              mode: 0o700
            ) do |private_directory|
              publish_from_pinned_source!(
                destination_parent: destination_parent,
                destination_parent_path: destination.parent,
                destination_basename: destination.basename.to_s,
                private_directory: private_directory
              )
            end
          end
        end
      end
    end
    book_library_path
  rescue AmbiguousPublicationError
    # Publication may have succeeded into a directory which was renamed while
    # its descriptor was pinned. Never clear that reservation automatically:
    # doing so could orphan the only published copy under the old directory.
    @retain_reservation = true
    raise
  rescue Errno::EEXIST
    raise Error, "The reserved upload destination became occupied by another file"
  rescue Errno::EXDEV, Errno::EPERM, Errno::ENOTSUP, Errno::ELOOP, Errno::ENOTDIR => error
    raise Error, "The library filesystem cannot publish uploads atomically: #{error.message}"
  end

  def cleanup_source_after_completion!
    self.class.cleanup_completed_source!(upload)
  end

  def restore_and_clear!
    return false if @retain_reservation

    self.class.restore_and_clear!(upload)
  end

  def book_library_path
    display_path_for(upload.library_path)
  end

  def display_destination_path
    display_path_for(upload.destination_path)
  end

  private

  def configured_roots(book)
    configured = if book.audiobook?
      SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    elsif book.comicbook?
      SettingsService.get(:comicbook_output_path, default: "/comics")
    else
      SettingsService.get(:ebook_output_path, default: "/ebooks")
    end
    configured_root = Pathname(configured.to_s).expand_path
    [ configured_root, self.class.secure_configured_directory!(configured_root) ]
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Error => error
    raise Error, "The configured upload output path is not accessible: #{error.message}"
  end

  def digest_source!
    result = nil
    self.class.send(:with_pinned_absolute_directory, source_path.parent) do |parent|
      self.class.send(:with_pinned_child, parent, source_path.basename.to_s) do |file|
        stat = file.stat
        raise Error, "The upload source is not a regular file" unless stat.file?
        result = [ file_digest(file), stat.size ]
      end
    end
    result
  rescue Errno::ENOENT
    raise Error, "Source file not found: #{source_path}"
  rescue Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR => error
    raise Error, "The upload source is not accessible: #{error.message}"
  end

  def file_digest(file)
    self.class.send(:sha256_io, file)
  end

  def publish_from_pinned_source!(
    destination_parent:,
    destination_parent_path:,
    destination_basename:,
    private_directory:
  )
    temporary_basename = "upload_#{upload.id}.tmp"
    self.class.send(:native_unlinkat, private_directory.fileno, temporary_basename)

    self.class.send(:with_pinned_absolute_directory, source_path.parent) do |source_parent|
      self.class.send(:with_pinned_child, source_parent, source_path.basename.to_s) do |source|
        self.class.send(
          :validate_open_file!, source, upload.file_size, upload.content_sha256
        )
        descriptor = self.class.send(
          :native_openat,
          private_directory.fileno,
          temporary_basename,
          flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
          mode: 0o600
        )
        private_copy = IO.new(descriptor, "wb", autoclose: true)
        begin
          source.rewind
          IO.copy_stream(source, private_copy)
          private_copy.flush
          private_copy.fsync
          self.class.send(:native_fchmod, private_copy.fileno, FILE_MODE)
        ensure
          private_copy.close unless private_copy.closed?
        end
        private_directory.fsync
      end
    end

    temporary_stat = nil
    self.class.send(:with_pinned_child, private_directory, temporary_basename) do |private_copy|
      self.class.send(
        :validate_open_file!, private_copy, upload.file_size, upload.content_sha256
      )
      temporary_stat = private_copy.stat
    end
    self.class.send(
      :native_linkat,
      private_directory.fileno,
      temporary_basename,
      destination_parent.fileno,
      destination_basename
    )
    destination_parent.fsync
    self.class.send(:with_pinned_child, destination_parent, destination_basename) do |published|
      self.class.send(
        :validate_open_file!, published, upload.file_size, upload.content_sha256
      )
      unless self.class.send(:same_file_identity?, temporary_stat, published.stat)
        raise Error, "The upload destination changed during publication"
      end
    end
    validate_published_parent!(destination_parent_path, destination_parent)
  ensure
    if private_directory && temporary_basename
      self.class.send(:native_unlinkat, private_directory.fileno, temporary_basename)
      private_directory.fsync
    end
  end

  def validate_published_parent!(path, pinned_parent)
    self.class.send(:with_pinned_absolute_directory, path) do |current_parent|
      unless self.class.send(
        :same_file_identity?, current_parent.stat, pinned_parent.stat
      )
        raise AmbiguousPublicationError,
          "The upload destination directory changed during publication"
      end
    end
  rescue AmbiguousPublicationError
    raise
  rescue Error, SystemCallError => error
    raise AmbiguousPublicationError,
      "The upload destination directory changed during publication: #{error.message}"
  end

  def candidate(counter)
    suffix = counter == 1 ? "" : " (#{counter})"
    if @flat_output
      extension = File.extname(@planned_filename)
      base = File.basename(@planned_filename, extension)
      destination = @root.join("#{base}#{suffix}#{extension}")
      [ destination, destination ]
    else
      directory = counter == 1 ? @planned_directory : Pathname("#{@planned_directory}#{suffix}")
      [ directory.join(@planned_filename), directory ]
    end
  end

  def occupied?(destination, library_path)
    self.class.send(:path_occupied?, library_path) ||
      Book.acquired.where(file_path: library_path.to_s).exists? ||
      Upload.blocking_reservations.where(library_path: library_path.to_s)
        .where.not(id: upload.id)
        .exists? ||
      Upload.blocking_reservations.where(destination_path: destination.to_s)
        .where.not(id: upload.id)
        .exists? ||
      OwnedMediaImport.blocking.where(library_path: library_path.to_s).exists? ||
      OwnedMediaImport.blocking.where(destination_path: destination.to_s).exists?
  end

  def validate_reservation!
    upload.reload
    unless self.class.complete_reservation?(upload)
      raise Error, "The upload destination reservation is incomplete"
    end

    root = self.class.send(:validated_reserved_root, upload)
    destination = Pathname(upload.destination_path).expand_path
    library_path = Pathname(upload.library_path).expand_path
    self.class.send(:validate_path_within_root!, destination, root)
    self.class.send(:validate_path_within_root!, library_path, root)
    true
  end

  def reserved_destination
    Pathname(upload.destination_path).expand_path
  end

  def display_path_for(raw_path)
    path = Pathname(raw_path.to_s).expand_path
    relative = path.relative_path_from(@root)
    raise Error, "The upload display path escaped its root" if relative.to_s.start_with?("..")

    @configured_root.join(relative).to_s
  end
end
