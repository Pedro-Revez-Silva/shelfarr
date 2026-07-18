# frozen_string_literal: true

require "digest"
require "fiddle"
require "pathname"

# Owns the filesystem handoff between a Libation backup and Shelfarr's
# audiobook library. Libation artifacts are first copied to a hidden staging
# directory on the audiobook filesystem. The final handoff can therefore use
# a same-filesystem hard link instead of copying a multi-gigabyte audiobook
# while SQLite is holding a write transaction.
#
# destination_path is persisted before finalization. If a worker is killed
# after the file is finalized but before the database commits, a later retry
# can recognize that exact file and finish the database work without losing or
# duplicating the audiobook.
class OwnedMediaImportFileService
  class Error < StandardError; end

  STAGING_DIRECTORY = ".shelfarr-staging"
  UPLOADS_DIRECTORY = "uploads"
  LOCKS_DIRECTORY = "locks"
  LOCK_SHARDS = 1_024
  LIBRARY_FILE_MODE = 0o640
  SOURCE_ONLY = :source_only
  DESTINATION_RETAINED = :destination_retained

  attr_reader :media_import, :upload, :book

  class << self
    def output_root
      configured = SettingsService.get(:audiobook_output_path, default: "/audiobooks")
      root = Pathname(configured.to_s.presence || "/audiobooks").expand_path
      FileUtils.mkdir_p(root)
      root.realpath
    rescue SystemCallError => e
      raise Error, "The configured audiobook output path is not accessible: #{e.message}"
    end

    def staging_upload_directory(root: output_root)
      database_fingerprint = Digest::SHA256.hexdigest(
        ActiveRecord::Base.connection_db_config.database.to_s
      ).first(12)
      directory = Pathname(root).join(
        STAGING_DIRECTORY,
        UPLOADS_DIRECTORY,
        database_fingerprint
      )
      secure_directory!(directory)
      directory.realpath
    end

    def staging_path_for(media_import, extension, root: output_root)
      raw_extension = extension.to_s
      extension = if raw_extension.start_with?(".") && !raw_extension.include?(File::SEPARATOR)
        raw_extension.downcase
      else
        File.extname(raw_extension).downcase
      end
      staging_upload_directory(root: root).join("libation_#{media_import.id}#{extension}")
    end

    # Copy a Libation artifact into durable staging through a pinned directory
    # descriptor. Only a complete, fsynced private file is atomically renamed
    # to the deterministic staging name, so hard exits never expose partial
    # bytes and ancestor swaps cannot redirect the write.
    def copy_io_to_staging!(media_import, source, extension, root: output_root)
      destination = staging_path_for(media_import, extension, root: root)
      basename = destination.basename.to_s
      temporary = ".#{basename}.#{SecureRandom.hex(16)}.tmp"
      size = nil
      copying = false

      secure_directory!(destination.dirname) do |directory|
        descriptor = class_native_openat(
          directory.fileno,
          temporary,
          flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
          mode: 0o600
        )
        copy = File.for_fd(descriptor, "wb", autoclose: true)
        begin
          source.rewind
          copying = true
          copy_io_contents(source, copy)
          copying = false
          copy.flush
          copy.fsync
          class_native_fchmod(copy.fileno, 0o600)
          size = copy.stat.size
        ensure
          copy.close unless copy.closed?
        end
        directory.fsync
        class_native_renameat(directory.fileno, temporary, directory.fileno, basename)
        directory.fsync
        validate_class_directory_path_identity!(destination.dirname, directory)
        with_class_pinned_regular_child(directory, basename) do |published|
          unless published.stat.size == size
            raise Error, "The durable Libation staging file changed during publication"
          end
        end
      ensure
        class_native_unlinkat(directory.fileno, temporary) if directory
      end

      [ destination.to_s, size ]
    rescue SystemCallError => error
      # Preserve media/storage failures raised while streaming the bytes. The
      # caller already records these as an unexpected import failure and may
      # distinguish ENOSPC/EIO for retry and operations diagnostics. Filesystem
      # validation failures around the copy remain normalized below.
      raise if copying

      raise Error, "Shelfarr could not stage the Libation audiobook safely: #{error.message}"
    end

    # Imports staged by an earlier Shelfarr beta lived below Rails tmp. Move
    # those files onto the durable audiobook filesystem before doing metadata
    # extraction or finalization. The large copy deliberately occurs outside
    # the library database transaction.
    def ensure_persistent_staging!(media_import, upload)
      if staging_path_syntax?(upload.file_path)
        output_root_for_staged_path(upload.file_path)
        return upload.file_path
      end
      return upload.file_path unless File.exist?(upload.file_path)

      root = output_root
      with_lock(root, "import-#{media_import.id}") do
        upload.reload
        if staging_path_syntax?(upload.file_path)
          output_root_for_staged_path(upload.file_path)
          return upload.file_path
        end
        return upload.file_path unless File.exist?(upload.file_path)

        original_path = Pathname(upload.file_path).expand_path
        destination = nil
        destination_size = nil
        with_class_pinned_regular_path(original_path) do |source|
          destination, destination_size = copy_io_to_staging!(
            media_import,
            source,
            upload.original_filename,
            root: root
          )
        end

        attached = upload.with_lock do
          upload.reload
          next false unless Pathname(upload.file_path).expand_path == original_path

          upload.update!(file_path: destination, file_size: destination_size)
          true
        end
        if attached
          # The ordinary temp-file sweeper removes the now-unreferenced legacy
          # source after its grace period. Avoid a validate-then-unlink race
          # against a pathname replacement here.
          destination
        else
          upload.reload.file_path
        end
      end
    end

    def staged_path?(raw_path)
      staging_components(raw_path).present?
    end

    def output_root_for_staged_path(raw_path)
      components = staging_components(raw_path)
      raise Error, "The Libation upload is not in Shelfarr's durable staging directory" unless components

      components.fetch(:root)
    end

    def recovery_source_path(media_import, upload)
      root = output_root_for_staged_path(upload.file_path)
      source = Pathname(upload.file_path).expand_path
      if regular_file_with_size?(source, upload.file_size) &&
          persisted_identity_matches?(media_import, File.lstat(source), allow_missing: true)
        return source.to_s
      end

      destination_value = media_import.reload.destination_path
      if destination_value.present?
        destination = Pathname(destination_value).expand_path
        staging_root = root.join(STAGING_DIRECTORY)
        if safe_library_destination?(destination, root, staging_root) &&
            regular_file_with_size?(destination, upload.file_size) &&
            persisted_identity_matches?(media_import, File.lstat(destination))
          return destination.to_s
        end
      end

      raise Error, "The staged Libation audiobook is missing"
    end

    def with_lock(root, key)
      lock_directory = Pathname(root).join(STAGING_DIRECTORY, LOCKS_DIRECTORY)
      shard = Digest::SHA256.hexdigest(key.to_s).to_i(16) % LOCK_SHARDS
      secure_directory!(lock_directory) do |locks|
        descriptor = class_native_openat(
          locks.fileno,
          format("lock-%04d", shard),
          flags: File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK,
          mode: 0o600
        )
        lock = File.for_fd(descriptor, "r+", autoclose: true)
        begin
          raise Error, "Shelfarr's audiobook lock is not a regular file" unless lock.stat.file?

          class_native_fchmod(lock.fileno, 0o600)
          unless lock.flock(File::LOCK_EX)
            raise Error, "The audiobook filesystem does not support Shelfarr's required lock"
          end
          yield
        ensure
          lock.close unless lock.closed?
        end
      end
    rescue Errno::ELOOP, Errno::EACCES, Errno::ENOENT => e
      raise Error, "Shelfarr could not lock the audiobook destination: #{e.message}"
    end

    # Audible backups rely on an advisory filesystem lock and a same-volume
    # hard link for their crash-safe final handoff. Probe those capabilities
    # before Libation spends time downloading a title so unsupported network
    # or removable filesystems fail immediately and without creating work.
    def verify_filesystem_capabilities!(root: output_root)
      root = Pathname(root).realpath
      with_lock(root, "capability-probe") do
        source = staging_upload_directory(root: root).join(
          ".capability-#{SecureRandom.hex(16)}"
        )
        destination = root.join(".shelfarr-capability-#{SecureRandom.hex(16)}")

        begin
          File.open(
            source.to_s,
            File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
            0o600
          ) { |file| file.write("shelfarr") }
          File.link(source, destination)
          unless File.identical?(source, destination)
            raise Error, "The audiobook filesystem did not create a stable hard link"
          end

          File.chmod(LIBRARY_FILE_MODE, destination)
          mode = File.stat(destination).mode & 0o777
          unless mode == LIBRARY_FILE_MODE
            raise Error, "The audiobook filesystem cannot apply Shelfarr's library file permissions"
          end
        ensure
          FileUtils.rm_f(destination) if destination
          FileUtils.rm_f(source) if source
        end
      end
      true
    rescue Error
      raise
    rescue SystemCallError => e
      raise Error,
        "The audiobook filesystem does not support Shelfarr's crash-safe finalization: #{e.message}"
    end

    private

    def staging_components(raw_path)
      return if raw_path.blank?

      path = Pathname(raw_path).expand_path
      uploads_ancestor = path.ascend.find do |candidate|
        candidate.basename.to_s == UPLOADS_DIRECTORY &&
          candidate.parent.basename.to_s == STAGING_DIRECTORY
      end
      return unless uploads_ancestor

      staging_root = uploads_ancestor.parent
      validate_directory_chain!(staging_root, path.parent)
      resolved_staging_root = staging_root.realpath
      resolved_parent = path.parent.realpath
      unless path_within?(resolved_parent, resolved_staging_root.join(UPLOADS_DIRECTORY).realpath)
        return
      end

      { path: path, root: resolved_staging_root.parent.realpath }
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      nil
    end

    def secure_directory!(directory)
      yielding_to_caller = false
      directory = Pathname(directory).expand_path
      staging_root = directory.ascend.find do |candidate|
        candidate.basename.to_s == STAGING_DIRECTORY
      end
      raise Error, "Shelfarr's staging path is invalid" unless staging_root

      lexical_parent = staging_root.parent.expand_path
      relative = directory.relative_path_from(lexical_parent)
      parent = lexical_parent.realpath
      directory = parent.join(relative)
      with_class_pinned_absolute_directory(parent) do |parent_directory|
        with_class_pinned_relative_directory(
          parent_directory,
          relative,
          create: true,
          mode: 0o700
        ) do |pinned_directory|
          current = File.lstat(directory)
          resolved = directory.realpath
          unless current.directory? && same_class_file_identity?(current, pinned_directory.stat) &&
              path_within?(resolved, parent.realpath)
            raise Error, "Shelfarr's staging path changed while it was being secured"
          end

          if block_given?
            yielding_to_caller = true
            return yield(pinned_directory)
          end
        end
      end
      true
    rescue SystemCallError => e
      raise if yielding_to_caller

      raise Error, "Shelfarr could not secure its audiobook staging directory: #{e.message}"
    end

    def with_class_pinned_absolute_directory(path)
      path = Pathname(path).expand_path
      handles = []
      current = File.open("/", File::RDONLY | File::NONBLOCK)
      handles << current
      path.each_filename do |part|
        child = open_class_pinned_directory_child(current, part)
        handles << child
        current = child
      end
      yield current
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    def with_class_pinned_relative_directory(parent, relative, create:, mode:)
      handles = []
      current = parent
      Pathname(relative).each_filename do |part|
        raise Error, "Shelfarr's staging path is invalid" if part.in?([ ".", ".." ])

        begin
          child = open_class_pinned_directory_child(current, part)
        rescue Errno::ENOENT
          raise unless create

          class_native_mkdirat(current.fileno, part, mode)
          child = open_class_pinned_directory_child(current, part)
        end
        class_native_fchmod(child.fileno, mode)
        handles << child
        current = child
      end
      yield current
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    def open_class_pinned_directory_child(parent, basename)
      descriptor = class_native_openat(
        parent.fileno,
        basename,
        flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
      directory = IO.new(descriptor, "rb", autoclose: true)
      unless directory.stat.directory?
        directory.close
        raise Error, "Shelfarr's staging path contains a symbolic link or non-directory component"
      end
      directory
    end

    def with_class_pinned_regular_path(path)
      path = Pathname(path).expand_path
      canonical_parent = path.parent.realpath
      with_class_pinned_absolute_directory(canonical_parent) do |parent|
        unless same_class_file_identity?(File.lstat(path.parent.realpath), parent.stat)
          raise Error, "The legacy upload source directory changed during staging"
        end
        with_class_pinned_regular_child(parent, path.basename.to_s) { |file| yield file }
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR => error
      raise Error, "The legacy upload source is not safely accessible: #{error.message}"
    end

    def with_class_pinned_regular_child(parent, basename)
      descriptor = class_native_openat(
        parent.fileno,
        basename,
        flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      )
      file = File.for_fd(descriptor, "rb", autoclose: true)
      begin
        raise Error, "The staged Libation upload is not a regular file" unless file.stat.file?

        yield file
      ensure
        file.close unless file.closed?
      end
    end

    def validate_class_directory_path_identity!(path, pinned_directory)
      resolved = Pathname(path).realpath
      current = File.lstat(resolved)
      unless current.directory? && same_class_file_identity?(current, pinned_directory.stat)
        raise Error, "The durable Libation staging directory changed during publication"
      end
      true
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "The durable Libation staging directory changed during publication"
    end

    def copy_io_contents(source, destination)
      IO.copy_stream(source, destination)
    rescue Errno::EACCES => error
      raise unless error.message.include?("copy_file_range")

      source.rewind
      destination.rewind
      destination.truncate(0)
      buffer = +""
      destination.write(buffer) while source.read(FileCopyService::BUFFER_SIZE, buffer)
    end

    def class_native_openat(directory_fd, basename, flags:, mode: 0)
      Fiddle.last_error = 0
      descriptor = if (flags & File::CREAT).positive?
        function = class_native_function(
          :openat_create,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC ],
          symbol: :openat
        )
        function.call(directory_fd, basename, flags, Fiddle::TYPE_INT, mode)
      else
        function = class_native_function(
          :openat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
        )
        function.call(directory_fd, basename, flags)
      end
      return descriptor unless descriptor == -1

      raise SystemCallError.new("openat", Fiddle.last_error)
    end

    def class_native_mkdirat(directory_fd, basename, mode)
      call_class_native_path_function(
        class_native_function(:mkdirat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        mode
      )
    rescue Errno::EEXIST
      nil
    end

    def class_native_fchmod(descriptor, mode)
      Fiddle.last_error = 0
      result = class_native_function(
        :fchmod,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ]
      ).call(descriptor, mode)
      return if result.zero?

      raise SystemCallError.new("fchmod", Fiddle.last_error)
    end

    def class_native_renameat(source_fd, source_basename, destination_fd, destination_basename)
      call_class_native_path_function(
        class_native_function(
          :renameat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ]
        ),
        source_fd,
        source_basename,
        destination_fd,
        destination_basename
      )
    end

    def class_native_unlinkat(directory_fd, basename)
      call_class_native_path_function(
        class_native_function(:unlinkat, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]),
        directory_fd,
        basename,
        0
      )
    rescue Errno::ENOENT
      nil
    end

    def call_class_native_path_function(function, *arguments)
      pointers = arguments.map do |argument|
        argument.is_a?(String) ? Fiddle::Pointer[argument + "\0"] : argument
      end
      Fiddle.last_error = 0
      result = function.call(*pointers)
      return result unless result == -1

      raise SystemCallError.new("filesystem operation", Fiddle.last_error)
    end

    def class_native_function(name, arguments, symbol: name)
      @class_native_functions ||= {}
      @class_native_functions[[ name, arguments ]] ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT[symbol.to_s],
        arguments,
        Fiddle::TYPE_INT
      )
    end

    def same_class_file_identity?(left, right)
      left.dev == right.dev && left.ino == right.ino
    end

    def staging_path_syntax?(raw_path)
      return false if raw_path.blank?

      Pathname(raw_path).expand_path.ascend.any? do |candidate|
        candidate.basename.to_s == UPLOADS_DIRECTORY &&
          candidate.parent.basename.to_s == STAGING_DIRECTORY
      end
    rescue ArgumentError
      false
    end

    def validate_directory_chain!(first, last)
      first = Pathname(first).expand_path
      last = Pathname(last).expand_path
      relative = last.relative_path_from(first)
      raise Error, "Shelfarr's staging path is invalid" if relative.to_s.start_with?("..")

      current = first
      [ current, *relative.each_filename.map { |part| current = current.join(part) } ].each do |path|
        stat = File.lstat(path)
        raise Error, "Shelfarr's staging path contains a symbolic link" unless stat.directory?
      end
      true
    rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "Shelfarr's staging directory is not accessible"
    end

    def copy_regular_file(source_path, destination)
      File.open(source_path.to_s, File::RDONLY | File::NOFOLLOW) do |source|
        raise Error, "The staged Libation upload is not a regular file" unless source.stat.file?

        FileCopyService.cp_io(source, destination.to_s)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
      raise Error, "The staged Libation upload is not accessible: #{e.message}"
    end

    def path_within?(path, root)
      path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
    end

    def regular_file_with_size?(path, expected_size)
      stat = File.lstat(path)
      stat.file? && (expected_size.blank? || stat.size == expected_size.to_i)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      false
    end

    def persisted_identity_matches?(media_import, stat, allow_missing: false)
      media_import.reload
      if media_import.staged_device.blank? || media_import.staged_inode.blank?
        return allow_missing
      end

      stat.dev == media_import.staged_device && stat.ino == media_import.staged_inode
    end

    def safe_library_destination?(destination, root, staging_root)
      return false unless path_within?(destination, root)
      return false if path_within?(destination, staging_root)

      resolved_parent = destination.parent.realpath
      path_within?(resolved_parent, root.realpath) &&
        !path_within?(resolved_parent, staging_root.realpath)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      false
    end
  end

  def initialize(media_import:, upload:, book:)
    @media_import = media_import
    @upload = upload
    @book = book
    @created_directories = []
    @output_root = self.class.output_root_for_staged_path(upload.file_path)
    if book.nil?
      destination = Pathname(media_import.destination_path.to_s).expand_path
      library_path = Pathname(media_import.library_path.to_s).expand_path
      unless media_import.destination_path.present? && media_import.library_path.present?
        raise Error, "The recoverable audiobook destination is incomplete"
      end

      @flat_output = library_path == destination
      @planned_directory = destination.dirname
      @planned_filename = destination.basename.to_s
      return
    end

    path_template = PathTemplateService.template_for(book)
    @flat_output = path_template.blank?
    relative_directory = PathTemplateService.build_path(book, path_template)
    @planned_directory = relative_directory.present? ?
      @output_root.join(relative_directory) : @output_root
    filename_template = PathTemplateService.filename_template_for(book)
    @planned_filename = PathTemplateService.build_filename(
      book,
      File.extname(upload.original_filename),
      template: filename_template
    )
  end

  def processing_path
    recovered = self.class.recovery_source_path(media_import, upload)
    return recovered if Pathname(recovered).expand_path == source_path

    restored = false
    with_existing_destination_lock { restored = restore_staging! }
    unless restored.in?([ SOURCE_ONLY, DESTINATION_RETAINED ])
      raise Error, "The finalized Libation audiobook could not be restored for validation"
    end

    source_path.to_s
  end

  def with_destination_lock
    canonical = library_lock_key
    self.class.with_lock(@output_root, "destination-#{canonical}") do
      reserve_destination!
      yield self
    end
  end

  # A failed processing attempt may need to put an already-finalized file back
  # into staging before metadata processing has reached destination planning.
  # Never create a new reservation on this recovery-only path.
  def with_existing_destination_lock
    return false if media_import.reload.destination_path.blank?

    self.class.with_lock(@output_root, "destination-#{library_lock_key}") do
      yield self
    end
    true
  end

  def finalize!
    destination = reserved_destination_path!
    validate_destination_path!(destination)
    validate_staging_parent!

    with_pinned_destination_parent(destination, create: true) do |destination_parent|
      destination_stat = pinned_child_stat(destination_parent, destination.basename.to_s)
      if path_exists_without_following?(source_path)
        with_verified_staged_source do |source, source_parent|
          source_stat = source.stat
          verify_persisted_staged_identity!(source_stat)

          if destination_stat
            validate_pinned_destination!(destination_parent, destination, source_stat: source_stat)
          else
            publish_pinned_hard_link!(
              source_parent: source_parent,
              source_stat: source_stat,
              destination_parent: destination_parent,
              destination: destination
            )
          end

          validate_pinned_destination_path_identity!(destination, destination_parent)
          unless pinned_child_matches?(source_parent, source_path.basename.to_s, source_stat)
            raise Error, "The staged Libation audiobook changed during finalization"
          end
          native_unlinkat(source_parent.fileno, source_path.basename.to_s)
          source_parent.fsync
        end
      elsif destination_stat
        validate_pinned_destination!(destination_parent, destination)
      else
        raise Error, "Both the staged and finalized Libation audiobook are missing"
      end
    end

    reserved_library_path!(destination)
  rescue Errno::EEXIST
    raise Error, "The planned audiobook destination became occupied"
  rescue Errno::EXDEV
    raise Error, "Shelfarr's Libation staging directory is not on the audiobook filesystem"
  rescue Errno::EPERM, Errno::ENOTSUP => e
    raise Error, "The audiobook filesystem does not support safe atomic finalization: #{e.message}"
  end

  # Restore a finalized file to staging after an ordinary exception causes the
  # surrounding database transaction to roll back. A hard process exit cannot
  # run this method; destination_path lets the next worker reconcile instead.
  def restore_staging!
    destination = reserved_destination_path
    return false unless destination

    validate_destination_path!(destination)
    validate_staging_parent!

    with_pinned_absolute_directory(source_path.parent) do |source_parent|
      with_pinned_destination_parent(destination, create: false) do |destination_parent|
        source_stat = pinned_child_stat(source_parent, source_path.basename.to_s)
        destination_stat = pinned_child_stat(destination_parent, destination.basename.to_s)
        if source_stat
          validate_stat!(source_stat, expected_size: upload.file_size)
          verify_persisted_staged_identity!(source_stat)
        end
        return SOURCE_ONLY if source_stat && !destination_stat
        return false unless destination_stat

        validate_stat!(destination_stat, expected_size: upload.file_size)
        verify_persisted_staged_identity!(destination_stat)
        if source_stat
          return false unless same_file_identity?(source_stat, destination_stat)
        else
          native_linkat(
            destination_parent.fileno,
            destination.basename.to_s,
            source_parent.fileno,
            source_path.basename.to_s
          )
          source_parent.fsync
          restored_stat = pinned_child_stat(source_parent, source_path.basename.to_s)
          return false unless restored_stat && same_file_identity?(restored_stat, destination_stat)
        end
        # Retain the finalized hard link and its durable reservation. Removing
        # a pathname after a separate identity check can delete a concurrent
        # replacement. The next retry safely reconciles the two hard links.
        return DESTINATION_RETAINED
      end
    end
    true
  rescue Errno::EEXIST, Errno::EXDEV, Errno::EPERM, Errno::ENOTSUP, Errno::ENOENT
    false
  end

  def clear_reservation!
    # Remove directories first. A hard exit after this point leaves the
    # reservation intact, so the next retry safely reuses the same path. The
    # reverse ordering could strand empty directories and force a spurious
    # "(2)" destination after a killed worker.
    remove_empty_created_directories!
    remove_empty_reserved_directories!
    media_import.with_lock do
      media_import.reload
      unless media_import.completed?
        media_import.update!(
          destination_path: nil,
          library_path: nil,
          staged_device: nil,
          staged_inode: nil
        )
      end
    end
  end

  private

  def reserve_destination!
    media_import.with_lock do
      media_import.reload
      ensure_persisted_staged_identity!
      if media_import.destination_path.present?
        destination = Pathname(media_import.destination_path).expand_path
        validate_destination_path!(destination)
        if media_import.library_path.blank?
          # Compatibility for a worker which reserved destination_path just
          # before the library_path migration was deployed. Flat output always
          # writes directly to the root; folder templates always add at least
          # one validated path segment.
          inferred_library_path = destination.dirname == @output_root ?
            destination.to_s : destination.dirname.to_s
          media_import.update!(library_path: inferred_library_path)
        end
        reserved_library_path!(destination)
        next media_import.destination_path
      end

      destination = first_available_destination
      media_import.update!(
        destination_path: destination.to_s,
        library_path: book_library_path(destination)
      )
      destination.to_s
    end
  rescue ActiveRecord::RecordNotUnique
    raise Error, "Another audiobook import reserved the same destination"
  end

  def first_available_destination
    counter = 1
    loop do
      candidate = destination_candidate(counter)
      return candidate unless destination_occupied?(candidate)

      counter += 1
    end
  end

  def destination_candidate(counter)
    directory = @planned_directory
    filename = @planned_filename

    if @flat_output
      base = File.basename(filename, File.extname(filename))
      suffix = counter == 1 ? "" : " (#{counter})"
      directory.join("#{base}#{suffix}#{File.extname(filename)}")
    else
      directory = Pathname("#{directory} (#{counter})") if counter > 1
      directory.join(filename)
    end
  end

  def canonical_destination_path
    destination_candidate(1).expand_path
  end

  def library_lock_key
    media_import.reload
    value = media_import.library_path
    if value.blank? && media_import.destination_path.present?
      destination = Pathname(media_import.destination_path).expand_path
      value = destination.dirname == @output_root ? destination.to_s : destination.dirname.to_s
    end
    library_path = Pathname(value.presence || book_library_path(canonical_destination_path)).expand_path
    unless path_within?(library_path, @output_root) &&
        library_path != @output_root &&
        !path_within?(library_path, @output_root.join(STAGING_DIRECTORY))
      raise Error, "The planned audiobook library path is outside the configured library"
    end

    library_path.to_s
  end

  def destination_occupied?(candidate)
    tracked_path = book_library_path(candidate)
    filesystem_path = @flat_output ? candidate : candidate.dirname

    path_exists_without_following?(filesystem_path) ||
      Book.acquired.where(file_path: tracked_path).where.not(id: book.id).exists? ||
      Upload.blocking_reservations
        .where.not(id: upload.id)
        .where("destination_path = :destination OR library_path = :library",
          destination: candidate.to_s, library: tracked_path)
        .exists? ||
      OwnedMediaImport.blocking.where(library_path: tracked_path).where.not(id: media_import.id).exists?
  end

  def book_library_path(destination)
    @flat_output ? destination.to_s : destination.dirname.to_s
  end

  def reserved_library_path!(destination)
    value = media_import.reload.library_path
    raise Error, "The audiobook library path was not reserved" if value.blank?

    library_path = Pathname(value).expand_path
    allowed_paths = [ destination.expand_path, destination.dirname.expand_path ]
    unless allowed_paths.include?(library_path)
      raise Error, "The planned audiobook library path is inconsistent"
    end

    library_path.to_s
  end

  def source_path
    @source_path ||= Pathname(upload.file_path).expand_path
  end

  def ensure_persisted_staged_identity!
    if media_import.staged_device.present? && media_import.staged_inode.present?
      return true
    end

    validate_staging_parent!
    with_pinned_absolute_directory(source_path.parent) do |source_parent|
      with_pinned_child(source_parent, source_path.basename.to_s) do |source|
        stat = source.stat
        validate_stat!(stat, expected_size: upload.file_size)
        media_import.update!(staged_device: stat.dev, staged_inode: stat.ino)
      end
    end
    true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The staged Libation audiobook identity could not be recorded"
  end

  def reserved_destination_path
    value = media_import.reload.destination_path
    value.present? ? Pathname(value).expand_path : nil
  end

  def reserved_destination_path!
    reserved_destination_path || raise(Error, "The audiobook destination was not reserved")
  end

  def validate_destination_path!(destination)
    root = @output_root.realpath
    expanded = destination.expand_path
    unless path_within?(expanded, root) && !path_within?(expanded, root.join(STAGING_DIRECTORY))
      raise Error, "The planned audiobook destination is outside the configured library"
    end
  end

  def remove_empty_created_directories!
    @created_directories.reverse_each do |directory|
      Dir.rmdir(directory)
    rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EEXIST
      # A concurrent import may legitimately be using this shared directory.
    end
    @created_directories.clear
  end

  def remove_empty_reserved_directories!
    destination = reserved_destination_path
    return unless destination

    library_path = media_import.reload.library_path
    return if library_path.blank?

    library_path = Pathname(library_path).expand_path
    # Flat layouts reserve the file itself and must never attempt to remove the
    # shared output root. Folder layouts can safely prune the now-empty title
    # directory left by a crashed worker, followed by empty template parents.
    return if library_path == destination

    current = destination.dirname
    root = @output_root.realpath
    while current != root && path_within?(current, root)
      Dir.rmdir(current)
      current = current.parent
    end
  rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EEXIST
    nil
  end

  def validate_staging_parent!
    root = self.class.output_root_for_staged_path(source_path)
    unless root.realpath == @output_root.realpath
      raise Error, "The Libation staging path changed during import"
    end

    true
  end

  def publish_pinned_hard_link!(source_parent:, source_stat:, destination_parent:, destination:)
    basename = destination.basename.to_s
    native_linkat(
      source_parent.fileno,
      source_path.basename.to_s,
      destination_parent.fileno,
      basename
    )
    destination_parent.fsync
    validate_pinned_destination!(destination_parent, destination, source_stat: source_stat)
  end

  def validate_pinned_destination!(directory, destination, source_stat: nil)
    with_pinned_child(directory, destination.basename.to_s) do |file|
      stat = file.stat
      validate_stat!(stat, expected_size: upload.file_size)
      verify_persisted_staged_identity!(stat)
      if source_stat && !same_file_identity?(source_stat, stat)
        raise Error, "The planned audiobook destination is occupied by another file"
      end

      native_fchmod(file.fileno, LIBRARY_FILE_MODE)
      stat
    end
  end

  def validate_pinned_destination_path_identity!(destination, directory)
    resolved_parent = destination.dirname.realpath
    resolved_root = @output_root.realpath
    current_stat = File.lstat(destination.dirname)
    unless path_within?(resolved_parent, resolved_root) &&
        !path_within?(resolved_parent, resolved_root.join(STAGING_DIRECTORY)) &&
        current_stat.directory? &&
        same_file_identity?(current_stat, directory.stat)
      raise Error, "The planned audiobook destination changed during finalization"
    end
    true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The planned audiobook destination changed during finalization"
  end

  # Resolve the configured output root from `/` one component at a time, then
  # resolve/create the destination path relative to that pinned root. O_NOFOLLOW
  # applies to every component, not only the leaf, closing ancestor-symlink
  # swaps between a realpath check and publication.
  def with_pinned_destination_parent(destination, create:)
    destination = Pathname(destination).expand_path
    relative = destination.dirname.relative_path_from(@output_root)
    if relative.to_s.start_with?("..") || path_within?(destination, @output_root.join(STAGING_DIRECTORY))
      raise Error, "The planned audiobook destination is outside the configured library"
    end

    with_pinned_absolute_directory(@output_root) do |root|
      with_pinned_relative_directory(root, relative, create: create) { |directory| yield directory }
    end
  rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
    raise Error, "The planned audiobook destination is not accessible: #{e.message}"
  end

  def with_pinned_absolute_directory(path)
    path = Pathname(path).expand_path
    handles = []
    root = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW)
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

  def with_pinned_relative_directory(root, relative, create:)
    handles = []
    current = root
    current_path = @output_root
    relative.each_filename do |part|
      next if part == "."
      raise Error, "The planned audiobook destination is outside the configured library" if part == ".."

      current_path = current_path.join(part)
      begin
        child = open_pinned_directory_child(current, part)
      rescue Errno::ENOENT
        raise unless create

        native_mkdirat(current.fileno, part, 0o750)
        @created_directories << current_path
        child = open_pinned_directory_child(current, part)
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
      flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
    directory = IO.new(descriptor, "rb", autoclose: true)
    unless directory.stat.directory?
      directory.close
      raise Error, "The planned audiobook destination contains a symbolic link or non-directory path"
    end
    directory
  end

  def with_pinned_child(directory, basename)
    descriptor = native_openat(
      directory.fileno,
      basename,
      flags: File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    )
    file = IO.new(descriptor, "rb", autoclose: true)
    begin
      raise Error, "The planned audiobook destination is not a regular file" unless file.stat.file?

      yield file
    ensure
      file.close unless file.closed?
    end
  end

  def pinned_child_matches?(directory, basename, expected_stat)
    with_pinned_child(directory, basename) do |child|
      return same_file_identity?(child.stat, expected_stat)
    end
  rescue Error, SystemCallError
    false
  end

  def pinned_child_stat(directory, basename)
    with_pinned_child(directory, basename) { |child| child.stat }
  rescue Errno::ENOENT
    nil
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

  def native_openat(directory_fd, basename, flags: File::RDONLY | File::NOFOLLOW)
    function = native_function(
      :openat,
      [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT ]
    )
    Fiddle.last_error = 0
    descriptor = function.call(directory_fd, basename, flags, 0)
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

  def native_fchmod(descriptor, mode)
    call_native_path_function(
      native_function(:fchmod, [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ]),
      descriptor,
      mode
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
  rescue Fiddle::DLError => e
    raise Error, "The audiobook filesystem cannot safely pin destinations: #{e.message}"
  end

  def with_verified_staged_source
    validate_staging_parent!
    with_pinned_absolute_directory(source_path.parent) do |source_parent|
      with_pinned_child(source_parent, source_path.basename.to_s) do |source|
        stat = source.stat
        validate_stat!(stat, expected_size: upload.file_size)
        verify_persisted_staged_identity!(stat)
        yield source, source_parent
      end
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The Libation audiobook is not accessible"
  end

  def verify_persisted_staged_identity!(stat)
    media_import.reload
    if media_import.staged_device.blank? || media_import.staged_inode.blank?
      raise Error, "The staged Libation audiobook identity was not recorded"
    end
    unless stat.dev == media_import.staged_device && stat.ino == media_import.staged_inode
      raise Error, "The staged Libation audiobook identity changed during import"
    end

    true
  end

  def same_file_identity?(left, right)
    left.dev == right.dev && left.ino == right.ino
  end

  def valid_regular_file?(path, expected_size:)
    validate_regular_file!(path, expected_size: expected_size)
    true
  rescue Error
    false
  end

  def validate_regular_file!(path, expected_size:)
    stat = File.lstat(path)
    raise Error, "The Libation audiobook path is not a regular file" unless stat.file?
    if expected_size.present? && stat.size != expected_size.to_i
      raise Error, "The Libation audiobook size changed during import"
    end

    true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The Libation audiobook is not accessible"
  end

  def validate_stat!(stat, expected_size:)
    raise Error, "The Libation audiobook path is not a regular file" unless stat.file?
    if expected_size.present? && stat.size != expected_size.to_i
      raise Error, "The Libation audiobook size changed during import"
    end

    true
  end

  def path_exists_without_following?(path)
    File.lstat(path)
    true
  rescue Errno::ENOENT
    false
  end

  def path_within?(path, root)
    path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
  end
end
