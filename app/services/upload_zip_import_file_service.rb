# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"
require "zip"

# Crash-safe publication for manually uploaded audiobook ZIP archives.
#
# The archive is expanded into a private directory on the library filesystem.
# Every output component is opened relative to pinned directory descriptors,
# every byte is counted while it is decompressed, and every file is fsynced.
# A content manifest is written last. The complete tree is then published with
# one atomic, no-replace directory rename. The source ZIP and manifest remain
# available until the database transaction records completion, which makes a
# killed worker safely resumable.
class UploadZipImportFileService
  class Error < StandardError; end
  class AmbiguousPublicationError < Error; end

  PRIVATE_DIRECTORY = ".shelfarr-upload-zip-staging"
  MANIFEST_FILENAME = ".shelfarr-upload-manifest.json"
  MANIFEST_VERSION = 1
  MANIFEST_MAX_BYTES = 10.megabytes
  FILE_MODE = 0o640
  PRIVATE_DIRECTORY_MODE = 0o700
  MAX_CANDIDATES = 10_000
  MAX_ENTRY_PATH_BYTES = 4_096
  MAX_ENTRY_COMPONENT_BYTES = 255
  MAX_ENTRY_DEPTH = 128
  MAX_CENTRAL_DIRECTORY_BYTES = 32.megabytes
  MAX_TREE_ENTRY_FACTOR = 2
  MANIFEST_ENTRY_OVERHEAD_BYTES = 160
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :upload, :source_path

  class << self
    def archive_upload?(upload)
      upload.audiobook_file? && File.extname(upload.original_filename).casecmp?(".zip")
    end

    def recovery_source_path(upload)
      source = canonical_source_path(upload.cleanup_source_path.presence || upload.file_path.to_s)
      with_pinned_regular_path(source) { |_file| nil }
      return source.to_s unless complete_reservation?(upload)

      validate_source!(source, upload.file_size, upload.content_sha256)
      source.to_s
    end

    def cleanup_completed_source!(upload, publication_already_verified: false)
      upload.reload
      return true if upload.cleanup_source_path.blank?
      return false unless upload.completed? && complete_reservation?(upload)

      root = validated_reserved_root(upload)
      destination = validated_reserved_destination(upload, root)
      source = Pathname(upload.cleanup_source_path).expand_path

      # A missing marker after the ZIP was truncated means an earlier cleanup
      # reached its final, idempotent filesystem step and died before clearing
      # cleanup_source_path in SQLite.
      unless publication_already_verified || publication_complete?(upload, destination, root)
        return finish_interrupted_cleanup(upload, source, destination)
      end

      truncate_verified_source!(source, upload.file_size, upload.content_sha256)
      remove_verified_manifest!(upload, destination, root, already_verified: true)
      clear_cleanup_source!(upload)
      true
    rescue Errno::ENOENT
      # A source which was already unlinked by external retention cleanup is
      # safe to forget only while our complete publication still verifies.
      return false unless publication_complete?(upload, destination, root)

      remove_verified_manifest!(upload, destination, root, already_verified: true)
      clear_cleanup_source!(upload)
      true
    rescue Error, FileCopyService::UnsafePathError, SystemCallError => error
      Rails.logger.error(
        "[UploadZipImportFileService] Could not finish ZIP upload ##{upload.id}: " \
          "#{error.class}: #{error.message}"
      )
      false
    end

    # Kept as a small compatibility surface for focused extraction tests. It
    # uses the same private-tree + atomic-publication pipeline as production.
    def extract_archive_to_new_directory!(
      zip_path,
      destination,
      max_bytes:,
      max_files:
    )
      destination = Pathname(destination).expand_path
      root = destination.parent.realpath
      destination = root.join(destination.basename)
      source = canonical_source_path(zip_path)
      temporary = root.join(".shelfarr-zip-test-#{SecureRandom.hex(16)}")
      digest, size = source_identity(source)

      begin
        FileCopyService.secure_private_directory!(temporary, root: root)
        ArchiveExtractor.new(
          source_path: source,
          source_size: size,
          source_digest: digest,
          staging_path: temporary,
          staging_root: root,
          upload_id: "standalone-#{SecureRandom.hex(8)}",
          max_bytes: max_bytes,
          max_files: max_files
        ).extract!
        snapshot = FileCopyService.snapshot_source_root(temporary)
        FileCopyService.mv_directory_noreplace(
          temporary,
          destination,
          root: root,
          source_root: snapshot
        )
        remove_manifest_by_path!(destination, root)
        destination.to_s
      rescue Errno::EEXIST
        raise Error, "ZIP archive would overwrite an existing file or directory"
      ensure
        remove_tree_if_present(temporary)
      end
    rescue Zip::Error => error
      raise Error, "Failed to extract audiobook archive: #{error.message}"
    rescue FileCopyService::UnsafePathError,
      FileCopyService::AtomicPublicationUnsupportedError,
      SystemCallError => error
      raise Error, "Failed to extract audiobook archive: #{error.message}"
    end

    def complete_reservation?(upload)
      upload.destination_path.present? &&
        upload.destination_root.present? &&
        upload.destination_configured_root.present? &&
        upload.library_path.present? &&
        upload.content_sha256.to_s.match?(SHA256_PATTERN)
    end

    def publication_complete?(upload, destination = nil, root = nil)
      return false unless complete_reservation?(upload)

      root ||= validated_reserved_root(upload)
      destination ||= validated_reserved_destination(upload, root)
      marker, actual = manifest_and_content(destination, root)
      marker.fetch("version") == MANIFEST_VERSION &&
        marker.fetch("upload_id").to_s == upload.id.to_s &&
        marker.fetch("source_sha256") == upload.content_sha256 &&
        marker.fetch("entries") == actual
    rescue Error, KeyError, JSON::ParserError, FileCopyService::UnsafePathError,
      Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, Errno::ESTALE
      false
    end

    private

    def source_identity(path)
      result = nil
      with_pinned_regular_path(path) do |file|
        stat = file.stat
        result = [ sha256_io(file), stat.size ]
      end
      result
    end

    def canonical_source_path(path)
      expanded = Pathname(path).expand_path
      expanded.parent.realpath.join(expanded.basename)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR => error
      raise Error, "The uploaded ZIP is not safely accessible: #{error.message}"
    end

    def validated_reserved_root(upload)
      root = Pathname(upload.destination_root.to_s).expand_path
      unless root.realpath.to_s == root.to_s
        raise Error, "The reserved ZIP upload root changed after it was planned"
      end

      root
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "The reserved ZIP upload root is not accessible"
    end

    def validated_reserved_destination(upload, root)
      destination = Pathname(upload.destination_path.to_s).expand_path
      library = Pathname(upload.library_path.to_s).expand_path
      validate_within_root!(destination, root)
      validate_within_root!(library, root)
      unless destination == library
        raise Error, "The ZIP upload reservation does not describe one atomic directory"
      end

      destination
    end

    def validate_within_root!(path, root)
      return if path.to_s.start_with?("#{root}#{File::SEPARATOR}")

      raise Error, "The ZIP upload destination escaped its reserved root"
    end

    def validate_source!(path, expected_size, expected_digest)
      with_pinned_regular_path(path) do |file|
        stat = file.stat
        raise Error, "The uploaded ZIP size changed" unless stat.size == expected_size.to_i
        raise Error, "The uploaded ZIP content changed" unless sha256_io(file) == expected_digest
      end
      true
    rescue Errno::ENOENT
      raise Error, "The uploaded ZIP is missing"
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR => error
      raise Error, "The uploaded ZIP is not safely accessible: #{error.message}"
    end

    def truncate_verified_source!(path, expected_size, expected_digest)
      UploadImportFileService.send(
        :with_pinned_file,
        path,
        flags: File::RDWR | File::NOFOLLOW | File::NONBLOCK
      ) do |file, _parent|
        stat = file.stat
        raise Error, "The uploaded ZIP path is not a regular file" unless stat.file?

        unless stat.size.zero?
          raise Error, "The uploaded ZIP size changed" unless stat.size == expected_size.to_i
          raise Error, "The uploaded ZIP content changed" unless sha256_io(file) == expected_digest

          UploadImportFileService.send(:native_ftruncate, file.fileno, 0)
          file.fsync
        end
      end
    end

    def finish_interrupted_cleanup(upload, source, destination)
      zero_source = with_pinned_regular_path(source) { |file| file.stat.size.zero? }
      return false unless zero_source
      root = Pathname(upload.destination_root).expand_path
      configured = Pathname(upload.destination_configured_root).expand_path
      expected_display_path = configured.join(destination.relative_path_from(root)).to_s
      return false unless upload.book&.file_path.to_s.in?([ destination.to_s, expected_display_path ])
      return false unless safely_open_directory?(destination, Pathname(upload.destination_root))

      clear_cleanup_source!(upload)
      true
    rescue Errno::ENOENT, Error, FileCopyService::UnsafePathError, SystemCallError
      false
    end

    def clear_cleanup_source!(upload)
      Upload.where(id: upload.id, status: Upload.statuses[:completed])
        .update_all(cleanup_source_path: nil, updated_at: Time.current)
      upload.reload
    end

    def safely_open_directory?(path, root)
      opened = false
      FileCopyService.send(
        :with_pinned_directory,
        path,
        root: root,
        create: false,
        mode: FileCopyService::DIRECTORY_MODE
      ) { |directory| opened = directory.stat.directory? }
      opened
    end

    def manifest_and_content(path, root)
      marker = nil
      actual = {}
      FileCopyService.send(
        :with_pinned_directory,
        path,
        root: root,
        create: false,
        mode: FileCopyService::DIRECTORY_MODE
      ) do |directory|
        marker = read_pinned_child(directory, MANIFEST_FILENAME, limit: MANIFEST_MAX_BYTES)
        FileCopyService.send(:digest_pinned_regular_tree, directory, manifest: actual)
        FileCopyService.send(:validate_current_directory_identity!, Pathname(path), directory)
      end
      actual.delete(MANIFEST_FILENAME)
      [ JSON.parse(marker), actual ]
    end

    def remove_verified_manifest!(upload, destination, root, already_verified: false)
      unless already_verified || publication_complete?(upload, destination, root)
        raise Error, "The ZIP publication changed before its recovery marker could be removed"
      end

      remove_manifest_by_path!(destination, root)
    end

    def remove_manifest_by_path!(destination, root)
      FileCopyService.send(
        :with_pinned_directory,
        destination,
        root: root,
        create: false,
        mode: FileCopyService::DIRECTORY_MODE
      ) do |directory|
        FileCopyService.send(:remove_pinned_regular_child, directory, MANIFEST_FILENAME)
        directory.fsync
        marker_remaining = begin
          FileCopyService.send(:pinned_child_identity, directory, MANIFEST_FILENAME)
          true
        rescue Errno::ENOENT
          false
        end
        if marker_remaining
          raise Error, "The ZIP publication manifest could not be removed safely"
        end
        FileCopyService.send(:validate_current_directory_identity!, Pathname(destination), directory)
      end
    end

    def read_pinned_child(directory, basename, limit:)
      value = nil
      FileCopyService.send(:with_pinned_regular_child, directory, basename) do |file|
        raise Error, "ZIP publication manifest is too large" if file.stat.size > limit

        value = file.read(limit + 1)
        raise Error, "ZIP publication manifest is too large" if value.bytesize > limit
      end
      value
    end

    def with_pinned_regular_path(path, &block)
      UploadImportFileService.send(:with_pinned_file, Pathname(path).expand_path, &block)
    end

    def sha256_io(io)
      UploadImportFileService.send(:sha256_io, io)
    end

    def remove_tree_if_present(path)
      return unless File.exist?(path) || File.symlink?(path)

      snapshot = FileCopyService.snapshot_source_root(path)
      FileCopyService.remove_source_tree(snapshot)
    rescue Errno::ENOENT
      nil
    end
  end

  def initialize(upload:, book:, max_bytes:, max_files:)
    raise Error, "Only audiobook ZIP uploads use this importer" unless self.class.archive_upload?(upload)
    if upload.destination_root.blank? && PathTemplateService.flat_output?(book)
      raise Error, "Audiobook ZIP uploads require a per-book path template"
    end

    @upload = upload
    @book = book
    @max_bytes = max_bytes
    @max_files = max_files
    @source_path = if upload.cleanup_source_path.present?
      Pathname(upload.cleanup_source_path).expand_path
    else
      self.class.send(:canonical_source_path, upload.file_path)
    end

    if upload.destination_root.present?
      @root = self.class.send(:validated_reserved_root, upload)
      @configured_root = validated_configured_root
    else
      @configured_root, @root = configured_roots
    end
    @planned_directory = if upload.library_path.present?
      Pathname(upload.library_path).expand_path
    else
      Pathname(PathTemplateService.build_destination(book, base_path: @root.to_s)).expand_path
    end
    self.class.send(:validate_within_root!, @planned_directory, @root)
  end

  def reserve!
    return validate_reservation! if upload.destination_path.present?

    digest, source_size = self.class.send(:source_identity, source_path)
    OwnedMediaImportFileService.with_lock(@root, "destination-#{@planned_directory}") do
      counter = 1
      loop do
        raise Error, "Shelfarr could not find an available ZIP destination" if counter > MAX_CANDIDATES

        destination = candidate(counter)
        if occupied?(destination)
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
            library_path: destination.to_s,
            content_sha256: digest,
            cleanup_source_path: source_path.to_s,
            file_size: source_size,
            updated_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique
          counter += 1
          next
        end

        upload.reload
        return validate_reservation! if claimed == 1 || upload.destination_path.present?

        raise Error, "The ZIP upload is no longer available for destination planning"
      end
    end
  end

  def publish!
    validate_reservation!
    root = self.class.send(:validated_reserved_root, upload)
    destination = self.class.send(:validated_reserved_destination, upload, root)

    OwnedMediaImportFileService.with_lock(root, "destination-#{destination}") do
      upload.reload
      validate_reservation!
      if self.class.publication_complete?(upload, destination, root)
        @publication_verified = true
        return display_destination_path
      end

      if File.exist?(destination) || File.symlink?(destination)
        raise Error, "The reserved ZIP destination became occupied by another file or directory"
      end

      FileCopyService.ensure_directory(destination.parent, root: root)
      ensure_complete_staging!(root)
      snapshot = FileCopyService.snapshot_source_root(staging_path(root))
      begin
        FileCopyService.mv_directory_noreplace(
          staging_path(root),
          destination,
          root: root,
          source_root: snapshot
        )
      rescue Errno::EEXIST
        if self.class.publication_complete?(upload, destination, root)
          @publication_verified = true
          return display_destination_path
        end

        raise Error, "The reserved ZIP destination became occupied by another file or directory"
      rescue Errno::ESTALE => error
        @retain_reservation = true
        raise AmbiguousPublicationError,
          "The ZIP publication path changed while it was being published: #{error.message}"
      end

      unless self.class.publication_complete?(upload, destination, root)
        @retain_reservation = true
        raise AmbiguousPublicationError, "The published ZIP directory could not be reconciled"
      end
      @publication_verified = true
    end
    display_destination_path
  rescue OwnedMediaImportFileService::Error,
    FileCopyService::UnsafePathError,
    FileCopyService::AtomicPublicationUnsupportedError,
    Errno::EXDEV, Errno::EPERM, Errno::ENOTSUP, Errno::ELOOP, Errno::ENOTDIR => error
    raise Error, "The library filesystem cannot safely publish ZIP uploads: #{error.message}"
  end

  def restore_and_clear!
    return false if @retain_reservation
    return true unless upload.reload.destination_path.present?

    root = self.class.send(:validated_reserved_root, upload)
    destination = self.class.send(:validated_reserved_destination, upload, root)
    OwnedMediaImportFileService.with_lock(root, "destination-#{destination}") do
      upload.reload
      return true if upload.completed?
      return false unless source_valid?

      if self.class.publication_complete?(upload, destination, root)
        return false unless remove_verified_tree(destination)
      elsif File.exist?(destination) || File.symlink?(destination)
        return false
      end

      remove_staging_tree(root)
      clear_reservation!
      true
    end
  rescue Error, OwnedMediaImportFileService::Error,
    FileCopyService::UnsafePathError, SystemCallError => error
    Rails.logger.error(
      "[UploadZipImportFileService] Could not restore ZIP upload ##{upload.id}: " \
        "#{error.class}: #{error.message}"
    )
    false
  end

  def cleanup_source_after_completion!
    self.class.cleanup_completed_source!(
      upload,
      publication_already_verified: @publication_verified
    )
  end

  def display_destination_path
    destination = Pathname(upload.destination_path.to_s).expand_path
    relative = destination.relative_path_from(@root)
    raise Error, "The ZIP upload display path escaped its root" if relative.to_s.start_with?("..")

    @configured_root.join(relative).to_s
  end

  private

  def configured_roots
    configured = SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    configured_root = Pathname(configured.to_s).expand_path
    [ configured_root, secure_configured_directory!(configured_root) ]
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
    raise Error, "The configured audiobook output path is not accessible: #{error.message}"
  end

  # Resolve the longest existing configured prefix once, pin that canonical
  # directory, and create only the missing suffix with mkdirat/openat. This
  # preserves legitimate aliases such as macOS /var -> /private/var while an
  # interposed or replaced component can never redirect the created root.
  def secure_configured_directory!(configured)
    if configured.exist?
      canonical = configured.realpath
      FileCopyService.send(:with_pinned_absolute_directory, canonical) do |directory|
        unless directory.stat.directory?
          raise Error, "The configured audiobook output path is not a directory"
        end
        FileCopyService.send(:validate_current_directory_identity!, configured, directory)
      end
      return canonical
    end

    missing = []
    existing = configured
    until existing.exist?
      raise Error, "The configured audiobook output path has no existing parent" if existing.root?

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
  rescue FileCopyService::UnsafePathError, Errno::ENOTDIR => error
    raise Error, "The configured audiobook output path is unsafe: #{error.message}"
  end

  def validated_configured_root
    configured = Pathname(upload.destination_configured_root.to_s).expand_path
    unless configured.realpath == @root
      raise Error, "The configured audiobook root changed after the ZIP was planned"
    end
    configured
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The configured audiobook output path is not accessible"
  end

  def validate_reservation!
    upload.reload
    raise Error, "The ZIP upload reservation is incomplete" unless self.class.complete_reservation?(upload)

    root = self.class.send(:validated_reserved_root, upload)
    self.class.send(:validated_reserved_destination, upload, root)
    configured = Pathname(upload.destination_configured_root.to_s).expand_path
    unless configured.realpath == root
      raise Error, "The configured audiobook root changed after the ZIP was planned"
    end
    true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "The configured audiobook output path is not accessible"
  end

  def candidate(counter)
    return @planned_directory if counter == 1

    Pathname("#{@planned_directory} (#{counter})")
  end

  def occupied?(destination)
    File.exist?(destination) ||
      File.symlink?(destination) ||
      Book.acquired.where(file_path: destination.to_s).exists? ||
      Upload.blocking_reservations.where.not(id: upload.id)
        .where("library_path = :path OR destination_path = :path", path: destination.to_s).exists? ||
      OwnedMediaImport.blocking
        .where("library_path = :path OR destination_path = :path", path: destination.to_s).exists?
  end

  def staging_path(root = @root)
    root.join(
      PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint),
      "upload_#{upload.id}.tmp"
    )
  end

  def ensure_complete_staging!(root)
    stage = staging_path(root)
    if File.exist?(stage) || File.symlink?(stage)
      return if staging_complete?(stage, root)

      remove_staging_tree(root)
    end

    FileCopyService.secure_private_directory!(stage, root: root)
    ArchiveExtractor.new(
      source_path: source_path,
      source_size: upload.file_size,
      source_digest: upload.content_sha256,
      staging_path: stage,
      staging_root: root,
      upload_id: upload.id,
      max_bytes: @max_bytes,
      max_files: @max_files
    ).extract!
    raise Error, "The extracted ZIP staging tree did not verify" unless staging_complete?(stage, root)
  rescue
    remove_staging_tree(root)
    raise
  end

  def staging_complete?(stage, root)
    marker, actual = self.class.send(:manifest_and_content, stage, root)
    marker.fetch("version") == MANIFEST_VERSION &&
      marker.fetch("upload_id").to_s == upload.id.to_s &&
      marker.fetch("source_sha256") == upload.content_sha256 &&
      marker.fetch("entries") == actual
  rescue Error, KeyError, JSON::ParserError, FileCopyService::UnsafePathError,
    Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, Errno::ESTALE
    false
  end

  def source_valid?
    self.class.send(:validate_source!, source_path, upload.file_size, upload.content_sha256)
  rescue Error
    false
  end

  def remove_staging_tree(root)
    stage = staging_path(root)
    return true unless File.exist?(stage) || File.symlink?(stage)

    snapshot = FileCopyService.snapshot_source_root(stage)
    FileCopyService.remove_source_tree(snapshot)
  end

  def remove_verified_tree(destination)
    snapshot = FileCopyService.snapshot_source_root(destination)
    return false unless self.class.publication_complete?(upload, destination, @root)

    FileCopyService.remove_source_tree(snapshot)
  end

  def clear_reservation!
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

  class ArchiveExtractor
    def initialize(
      source_path:,
      source_size:,
      source_digest:,
      staging_path:,
      staging_root:,
      upload_id:,
      max_bytes:,
      max_files:
    )
      @source_path = Pathname(source_path).expand_path
      @source_size = source_size.to_i
      @source_digest = source_digest
      @staging_path = Pathname(staging_path).expand_path
      @staging_root = Pathname(staging_root).expand_path
      @upload_id = upload_id
      @max_bytes = max_bytes.to_i
      @max_files = max_files.to_i
    end

    def extract!
      UploadZipImportFileService.send(:with_pinned_regular_path, @source_path) do |source|
        validate_source_descriptor!(source)
        ZipArchivePreflightService.validate!(
          source,
          max_entries: @max_files * 2,
          max_central_directory_bytes: MAX_CENTRAL_DIRECTORY_BYTES
        )
        # rubyzip reopens the archive for each entry. Point it at the already
        # pinned descriptor rather than at the attacker-replaceable upload
        # pathname. Both Linux and Darwin expose process descriptors this way.
        Zip::File.open(descriptor_path(source)) do |archive|
          files = validated_file_entries(archive.entries)
          total = 0
          manifest = {}

          files.each do |entry, relative|
            bytes, digest = write_entry(relative, entry) do |count|
              total += count
              if total > @max_bytes
                raise Error,
                  "ZIP archive exceeds #{@max_bytes / 1.megabyte} MB extracted size limit"
              end
            end
            add_parent_directories(manifest, relative)
            manifest[relative] = [ "file", bytes, digest ]
          end

          validate_source_descriptor!(source)
          write_manifest(manifest)
        end
      end
      true
    rescue Zip::Error, ZipArchivePreflightService::Error => error
      raise Error, "Failed to extract audiobook archive: #{error.message}"
    end

    private

    def descriptor_path(source)
      linux_path = "/proc/self/fd/#{source.fileno}"
      return linux_path if File.exist?(linux_path)

      "/dev/fd/#{source.fileno}"
    end

    def validated_file_entries(entries)
      if entries.size > (@max_files * 2)
        raise Error, "ZIP archive contains too many entries"
      end

      normalized = {}
      files = []
      tree_paths = {}
      estimated_manifest_bytes = 0

      entries.each do |entry|
        relative = normalize_entry_name(entry.name, directory: entry.directory?)
        next if entry.directory?

        if normalized.key?(relative)
          raise Error, "ZIP archive contains duplicate file path: #{entry_label(entry.name)}"
        end

        normalized[relative] = :file
        files << [ entry, relative ]

        path = Pathname(relative)
        components = path.each_filename.to_a
        components.each_index do |index|
          tree_path = components.first(index + 1).join("/")
          next if tree_paths.key?(tree_path)

          tree_paths[tree_path] = true
          estimated_manifest_bytes += tree_path.bytesize + MANIFEST_ENTRY_OVERHEAD_BYTES
          if tree_paths.size > @max_files * MAX_TREE_ENTRY_FACTOR
            raise Error, "ZIP archive expands to too many files and directories"
          end
          if estimated_manifest_bytes > MANIFEST_MAX_BYTES
            raise Error, "ZIP archive path manifest is too large"
          end
        end
      end

      raise Error, "ZIP archive did not contain any files" if files.empty?
      if files.size > @max_files
        raise Error, "ZIP archive contains too many files (max #{@max_files})"
      end

      normalized.each_key do |relative|
        parts = relative.split("/")
        (1...parts.length).each do |length|
          ancestor = parts.first(length).join("/")
          if normalized[ancestor] == :file
            raise Error, "ZIP archive contains conflicting file paths: #{entry_label(relative)}"
          end
        end
      end
      files
    end

    def normalize_entry_name(name, directory:)
      value = name.to_s
      value = value.delete_suffix("/") if directory
      segments = value.split("/", -1)
      unsafe = !value.valid_encoding? || value.blank? || value.start_with?("/", "\\") ||
        value.include?("\\") || value.include?("\0") ||
        value.bytesize > MAX_ENTRY_PATH_BYTES || segments.size > MAX_ENTRY_DEPTH ||
        segments.any? do |segment|
          segment.blank? || segment == "." || segment == ".." ||
            segment.bytesize > MAX_ENTRY_COMPONENT_BYTES || segment.match?(/[[:cntrl:]]/) ||
            segment.downcase.start_with?(".shelfarr")
        end
      raise Error, "ZIP archive contains an unsafe path: #{entry_label(name)}" if unsafe

      segments.join("/")
    end

    def entry_label(name)
      name.to_s.scrub("?").gsub(/[[:cntrl:]]/, "?").truncate(200)
    end

    def write_entry(relative, entry)
      result = nil
      with_staging_directory do |staging|
        parent_relative = Pathname(relative).dirname
        UploadImportFileService.send(
          :with_pinned_relative_directory,
          staging,
          parent_relative,
          create: true,
          mode: PRIVATE_DIRECTORY_MODE
        ) do |parent|
          basename = Pathname(relative).basename.to_s
          descriptor = UploadImportFileService.send(
            :native_openat,
            parent.fileno,
            basename,
            flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
            mode: 0o600
          )
          output = IO.new(descriptor, "wb", autoclose: true)
          bytes = 0
          digest = Digest::SHA256.new
          begin
            entry.get_input_stream do |input|
              buffer = +""
              while (chunk = input.read(1024 * 1024, buffer))
                next if chunk.empty?

                yield chunk.bytesize
                output.write(chunk)
                digest.update(chunk)
                bytes += chunk.bytesize
              end
            end
            output.flush
            output.fsync
            UploadImportFileService.send(:native_fchmod, output.fileno, FILE_MODE)
            result = [ bytes, digest.hexdigest ]
          ensure
            output.close unless output.closed?
          end
          parent.fsync
        rescue
          UploadImportFileService.send(:native_unlinkat, parent.fileno, basename) if parent && basename
          parent&.fsync
          raise
        end
      end
      result
    end

    def write_manifest(entries)
      payload = JSON.generate(
        version: MANIFEST_VERSION,
        upload_id: @upload_id.to_s,
        source_sha256: @source_digest,
        entries: entries
      )
      raise Error, "ZIP publication manifest is too large" if payload.bytesize > MANIFEST_MAX_BYTES

      with_staging_directory do |staging|
        descriptor = UploadImportFileService.send(
          :native_openat,
          staging.fileno,
          MANIFEST_FILENAME,
          flags: File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
          mode: 0o600
        )
        marker = IO.new(descriptor, "wb", autoclose: true)
        begin
          marker.write(payload)
          marker.flush
          marker.fsync
          UploadImportFileService.send(:native_fchmod, marker.fileno, FILE_MODE)
        ensure
          marker.close unless marker.closed?
        end
        staging.fsync
      end
    end

    def with_staging_directory
      FileCopyService.send(
        :with_pinned_directory,
        @staging_path,
        root: @staging_root,
        create: false,
        mode: PRIVATE_DIRECTORY_MODE
      ) { |directory| yield directory }
    end

    def validate_source_descriptor!(source)
      stat = source.stat
      raise Error, "The uploaded ZIP path is not a regular file" unless stat.file?
      raise Error, "The uploaded ZIP size changed" unless stat.size == @source_size
      unless UploadZipImportFileService.send(:sha256_io, source) == @source_digest
        raise Error, "The uploaded ZIP content changed"
      end
      source.rewind
    end

    def add_parent_directories(manifest, relative)
      parts = relative.split("/")
      (1...parts.length).each do |length|
        manifest[parts.first(length).join("/")] ||= [ "directory" ]
      end
    end
  end
end
