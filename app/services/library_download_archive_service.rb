# frozen_string_literal: true

require "digest"
require "pathname"
require "zip"

# Builds immutable, content-versioned ZIPs for directory-backed library items.
# Source traversal and archive reads use FileCopyService's no-follow pinned
# descriptors; final cache publication is private, coordinated, and atomic.
class LibraryDownloadArchiveService
  MAX_ARCHIVE_ENTRIES = 50_000
  MAX_ARCHIVE_DEPTH = 128
  # A 16-GiB ceiling still accommodates unusually large lossless box sets but
  # keeps two concurrent beta builds within an operationally meaningful disk
  # and I/O envelope on typical self-hosted systems.
  MAX_ARCHIVE_SOURCE_BYTES = 16 * 1024 * 1024 * 1024
  # Deflate can expand incompressible media slightly and ZIP metadata also
  # consumes space, so output receives a separate bounded allowance.
  MAX_ARCHIVE_OUTPUT_BYTES = MAX_ARCHIVE_SOURCE_BYTES + (128 * 1024 * 1024)
  # 50,000 legal entries can otherwise consume unbounded memory and central
  # directory space through long path names.
  MAX_ARCHIVE_NAME_BYTES = 32 * 1024 * 1024
  # Large network-backed libraries need room to complete, but a request must
  # never occupy a worker indefinitely.
  MAX_ARCHIVE_RUNTIME_SECONDS = 30 * 60
  MAX_ARCHIVE_COORDINATION_WAIT_SECONDS = 2
  MAX_ARCHIVE_ADMISSION_WAIT_SECONDS = 2
  ARCHIVE_ADMISSION_RETRY_SECONDS = 0.05
  ARCHIVE_BUILD_SLOTS = 2
  ARCHIVE_LOCK_SHARDS = 256
  CACHE_FORMAT_VERSION = 2
  CACHE_DIRECTORY = Rails.root.join("tmp", "downloads").freeze
  ZIP_EOCD_SIGNATURE = "PK\x05\x06".b.freeze
  ZIP_LOCAL_SIGNATURE = "PK\x03\x04".b.freeze
  MAX_ZIP_TRAILER_SIZE = 65_557
  WINDOWS_RESERVED_COMPONENT = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i

  class Error < StandardError; end
  class UnsafePathError < Error; end
  class SourceChangedError < Error; end
  class ResourceLimitError < Error; end
  class BusyError < Error; end

  def self.call(book:, source_path:, output_root:)
    new(book: book, source_path: source_path, output_root: output_root).call
  end

  def self.lock_path_for_book(book_id, directory: CACHE_DIRECTORY)
    shard = Integer(book_id) % ARCHIVE_LOCK_SHARDS
    Pathname(directory).join(format(".archive-lock-%02x", shard))
  end

  def self.admission_lock_paths(directory: CACHE_DIRECTORY)
    ARCHIVE_BUILD_SLOTS.times.map do |slot|
      Pathname(directory).join(format(".archive-build-slot-%02x", slot))
    end
  end

  def initialize(book:, source_path:, output_root:)
    @book = book
    @source_path = Pathname(source_path).expand_path
    @output_root = Pathname(output_root).expand_path
  end

  def call
    start_runtime_budget!
    canonical_root, canonical_source = validate_boundary!
    prepare_cache_directory!
    with_cache_coordination do
      # Admission by stable book shard precedes the potentially expensive tree
      # walk so repeated requests for the same item cannot all consume workers
      # while independently snapshotting one large directory.
      preflight_source_tree!(canonical_source, canonical_root)
      source_root = FileCopyService.snapshot_source_root(
        canonical_source,
        heartbeat: method(:enforce_runtime_budget!),
        max_entries: MAX_ARCHIVE_ENTRIES,
        max_depth: MAX_ARCHIVE_DEPTH
      )
      validate_snapshot!(source_root, canonical_root)
      cache_path = cache_path_for(source_root)

      unless cache_file_valid?(cache_path, source_root: source_root)
        repair_invalid_cache!(cache_path)
        with_build_admission do
          build_and_publish!(source_root, canonical_root, cache_path)
        end
      end
      FileCopyService.refresh_regular_file_times(cache_path, root: CACHE_DIRECTORY.to_s)
      validated_cache_path(cache_path, source_root: source_root)
    end
  rescue FileCopyService::UnsafePathError => error
    raise UnsafePathError, "library archive source is unsafe (#{error.class})"
  rescue Errno::ESTALE => error
    raise SourceChangedError, "library directory changed while its archive was prepared (#{error.class})"
  rescue ArgumentError, EncodingError => error
    raise UnsafePathError, "library archive contains an invalid path (#{error.class})"
  rescue FileCopyService::AtomicPublicationUnsupportedError => error
    raise Error, "library archive cannot be atomically published (#{error.class})"
  rescue SystemCallError, Zip::Error => error
    raise Error, "library archive could not be prepared (#{error.class})"
  end

  private

  def validate_boundary!
    enforce_runtime_budget!
    canonical_root = @output_root.realpath
    raise UnsafePathError, "filesystem root cannot be an archive boundary" if canonical_root.root?
    raise UnsafePathError, "archive boundary is not a directory" unless canonical_root.lstat.directory?

    canonical_source = @source_path.realpath
    unless canonical_source.lstat.directory? && strict_path_descendant?(canonical_source, canonical_root)
      raise UnsafePathError, "library archive source is outside its configured root"
    end

    enforce_runtime_budget!
    [ canonical_root, canonical_source ]
  end

  # This literal-name preflight rejects static symlinks and special files before
  # the descriptor snapshot attempts to open an entry. The descriptor snapshot
  # repeats type and identity checks to close ordinary pathname races.
  def preflight_source_tree!(canonical_source, canonical_root)
    entry_count = 0
    pending = [ [ canonical_source, 0 ] ]
    until pending.empty?
      directory, depth = pending.pop
      Dir.each_child(directory) do |entry|
        enforce_runtime_budget!
        validate_source_component!(entry)
        entry_count += 1
        raise UnsafePathError, "library directory contains too many entries" if entry_count > MAX_ARCHIVE_ENTRIES

        child = directory.join(entry)
        lexical_stat = File.lstat(child)
        unless lexical_stat.file? || lexical_stat.directory?
          raise UnsafePathError, "library tree contains a symbolic link or non-regular entry"
        end

        canonical_child = child.realpath
        canonical_stat = File.lstat(canonical_child)
        unless path_contained?(canonical_child, canonical_root) &&
            [ canonical_stat.dev, canonical_stat.ino ] == [ lexical_stat.dev, lexical_stat.ino ] &&
            canonical_stat.ftype == lexical_stat.ftype
          raise UnsafePathError, "library tree entry escaped its configured root"
        end

        if lexical_stat.directory?
          child_depth = depth + 1
          if child_depth > MAX_ARCHIVE_DEPTH
            raise UnsafePathError, "library directory nesting is too deep"
          end

          pending << [ canonical_child, child_depth ]
        end
      end
    end
  end

  def validate_source_component!(component)
    unless component.valid_encoding? && component.encode(Encoding::UTF_8).valid_encoding?
      raise UnsafePathError, "library tree contains an invalid filename"
    end
    if component.empty? || component.in?([ ".", ".." ]) || component.include?(File::SEPARATOR)
      raise UnsafePathError, "library tree contains an unsafe filename"
    end
  end

  def validate_snapshot!(source_root, canonical_root)
    enforce_runtime_budget!
    snapshot_path = Pathname(source_root.canonical_path)
    unless snapshot_path.lstat.directory? && strict_path_descendant?(snapshot_path, canonical_root)
      raise UnsafePathError, "library archive snapshot escaped its configured root"
    end
    if source_root.entries.size > MAX_ARCHIVE_ENTRIES
      raise UnsafePathError, "library directory contains too many entries"
    end

    source_bytes = 0
    name_bytes = 0
    source_root.entries.each do |relative, manifest|
      enforce_runtime_budget!
      relative_path = Pathname(relative)
      if relative_path.absolute? || relative_path.each_filename.any? { |component| component.in?([ ".", ".." ]) }
        raise UnsafePathError, "library archive snapshot contains an unsafe relative path"
      end
      unless manifest[2].in?([ :file, :directory ]) &&
          path_contained?(snapshot_path.join(relative_path).cleanpath, snapshot_path)
        raise UnsafePathError, "library archive snapshot contains an unsafe entry"
      end

      source_bytes += Integer(manifest[3]) if manifest[2] == :file
      name_bytes += safe_entry_name(relative, directory: manifest[2] == :directory).bytesize
      if source_bytes > max_archive_source_bytes
        raise ResourceLimitError, "library archive source exceeds its aggregate byte budget"
      end
      if name_bytes > max_archive_name_bytes
        raise ResourceLimitError, "library archive paths exceed their aggregate byte budget"
      end
    end
  end

  def strict_path_descendant?(path, root)
    path != root && path_contained?(path, root)
  end

  def path_contained?(path, root)
    return true if path == root

    path.to_s.start_with?("#{root.to_s.delete_suffix(File::SEPARATOR)}#{File::SEPARATOR}")
  end

  def cache_path_for(source_root)
    enforce_runtime_budget!
    fingerprint_payload = [
      CACHE_FORMAT_VERSION,
      source_root.canonical_path.to_s,
      source_root.device,
      source_root.inode,
      source_root.size,
      source_root.mtime,
      source_root.ctime,
      source_root.entries.sort_by { |relative, _manifest| relative }
    ]
    fingerprint = Digest::SHA256.hexdigest(Marshal.dump(fingerprint_payload))
    enforce_runtime_budget!
    CACHE_DIRECTORY.join("book_#{Integer(@book.id)}_v#{CACHE_FORMAT_VERSION}_#{fingerprint}.zip")
  end

  def build_and_publish!(source_root, canonical_root, cache_path)
    staged = FileCopyService.create_private_file(
      CACHE_DIRECTORY.to_s,
      root: CACHE_DIRECTORY.to_s,
      prefix: ".book_#{Integer(@book.id)}_archive-",
      suffix: ".zip"
    )

    begin
      write_archive!(staged.io, source_root)
      staged.io.flush
      staged.io.fsync
      staged.io.chmod(0o600)
      validate_unchanged_source!(source_root, canonical_root)
      publish_noreplace!(staged, cache_path, source_root)
    ensure
      staged.io.close unless staged.io.closed?
      FileCopyService.remove_private_file(staged, root: CACHE_DIRECTORY.to_s)
    end
  end

  def prepare_cache_directory!
    tmp_root = Rails.root.join("tmp")
    FileCopyService.ensure_directory(tmp_root.to_s, root: Rails.root.to_s, mode: 0o750)
    FileCopyService.secure_private_directory!(CACHE_DIRECTORY.to_s, root: tmp_root.to_s)
  end

  def write_archive!(output, source_root)
    used_names = {}
    @written_source_bytes = 0
    @written_name_bytes = 0
    enforce_runtime_budget!
    archive = Zip::OutputStream.new(output, stream: true)
    begin
      source_root.entries.sort_by { |relative, _manifest| relative }.each do |relative, manifest|
        enforce_runtime_budget!
        entry_name = safe_entry_name(relative, directory: manifest[2] == :directory)
        @written_name_bytes += entry_name.bytesize
        if @written_name_bytes > max_archive_name_bytes
          raise ResourceLimitError, "library archive paths exceeded their byte budget while being written"
        end
        collision_key = portable_collision_key(entry_name)
        raise UnsafePathError, "library paths collide in a portable ZIP archive" if used_names[collision_key]

        used_names[collision_key] = true
        archive.put_next_entry(entry_name)
        enforce_output_budget!(output)
        next if manifest[2] == :directory
        raise UnsafePathError, "library tree contains a non-regular entry" unless manifest[2] == :file

        canonical_source_path = Pathname(source_root.canonical_path).join(relative)
        FileCopyService.with_source_file(canonical_source_path, source_root: source_root) do |source|
          copy_to_archive(source, archive, output: output)
        end
      end
      archive.close_buffer
    ensure
      # rubyzip duplicates a caller-owned stream in stream mode and does not
      # close that duplicate from #close_buffer. Close it without finalizing
      # on failures so aborted builds cannot retain unlinked staging storage.
      archive_stream = archive.instance_variable_get(:@output_stream)
      archive_stream&.close unless archive_stream&.closed?
    end
    enforce_output_budget!(output)
    enforce_runtime_budget!
  end

  def safe_entry_name(relative, directory:)
    components = Pathname(relative).each_filename.to_a
    if components.empty? || components.any? { |component| component.empty? || component.in?([ ".", ".." ]) }
      raise UnsafePathError, "library tree contains an unsafe archive path"
    end

    sanitized = components.map { |component| safe_zip_component(component) }.join("/")
    if sanitized.start_with?("/", "//") || sanitized.match?(/\A[A-Za-z]:/) || sanitized.include?("\\")
      raise UnsafePathError, "library tree contains an unsafe archive path"
    end

    directory ? "#{sanitized}/" : sanitized
  end

  def safe_zip_component(component)
    raise UnsafePathError, "library tree contains an invalid filename" unless component.valid_encoding?

    value = component.encode(Encoding::UTF_8).unicode_normalize(:nfc)
    value = value.gsub(/[\\\/:*?"<>|\x00-\x1f\x7f]/, "_")
    value = value.gsub(/[ .]+\z/) { |suffix| "_" * suffix.length }
    value = "_" if value.empty?
    value = "_#{value}" if value.match?(WINDOWS_RESERVED_COMPONENT)
    value
  end

  def portable_collision_key(entry_name)
    entry_name.delete_suffix("/").unicode_normalize(:nfkc).downcase
  end

  def copy_to_archive(source, archive, output:)
    buffer = +""
    while source.read(FileCopyService::BUFFER_SIZE, buffer)
      @written_source_bytes += buffer.bytesize
      if @written_source_bytes > max_archive_source_bytes
        raise ResourceLimitError, "library archive source exceeded its byte budget while being read"
      end
      archive.write(buffer)
      enforce_output_budget!(output)
      enforce_runtime_budget!
    end
  end

  def validate_unchanged_source!(source_root, canonical_root)
    current = FileCopyService.snapshot_source_root(
      source_root.canonical_path,
      heartbeat: method(:enforce_runtime_budget!),
      max_entries: MAX_ARCHIVE_ENTRIES,
      max_depth: MAX_ARCHIVE_DEPTH
    )
    validate_snapshot!(current, canonical_root)
    unchanged = current.device == source_root.device &&
      current.inode == source_root.inode &&
      current.size == source_root.size &&
      current.mtime == source_root.mtime &&
      current.ctime == source_root.ctime &&
      current.entries == source_root.entries
    raise SourceChangedError, "library directory changed while its archive was built" unless unchanged
  end

  def publish_noreplace!(staged, cache_path, source_root)
    FileCopyService.publish_private_file_noreplace(
      staged,
      cache_path,
      root: CACHE_DIRECTORY.to_s,
      mode: 0o600
    )
  rescue Errno::EEXIST
    unless cache_file_valid?(cache_path, source_root: source_root)
      raise UnsafePathError, "archive cache path is not a trusted ZIP"
    end
  end

  def repair_invalid_cache!(cache_path)
    stat = File.lstat(cache_path)
    raise UnsafePathError, "archive cache path is not a regular file" unless stat.file?

    removed = FileCopyService.remove_regular_file_safely(
      cache_path,
      root: CACHE_DIRECTORY.to_s
    )
    raise SourceChangedError, "archive cache changed before repair" unless removed
  rescue Errno::ENOENT
    nil
  end

  def validated_cache_path(cache_path, source_root:)
    unless cache_file_valid?(cache_path, source_root: source_root)
      raise UnsafePathError, "archive cache is not a trusted ZIP"
    end

    canonical_cache = cache_path.realpath
    canonical_directory = CACHE_DIRECTORY.realpath
    unless path_contained?(canonical_cache, canonical_directory)
      raise UnsafePathError, "archive cache escaped its private directory"
    end

    canonical_cache.to_s
  end

  def cache_file_valid?(path, source_root:)
    enforce_runtime_budget!
    FileCopyService.with_regular_file(path, root: CACHE_DIRECTORY.to_s) do |file|
      stat = file.stat
      next false unless stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 &&
        stat.size.between?(22, max_archive_output_bytes)

      file.binmode
      file.rewind
      first_signature = file.read(4)
      next false unless first_signature.in?([ ZIP_LOCAL_SIGNATURE, ZIP_EOCD_SIGNATURE ])

      trailer_size = [ stat.size, MAX_ZIP_TRAILER_SIZE ].min
      file.seek(-trailer_size, IO::SEEK_END)
      trailer = file.read(trailer_size)
      eocd_offset = trailer.rindex(ZIP_EOCD_SIGNATURE)
      next false unless eocd_offset && eocd_offset + 22 <= trailer.bytesize

      comment_length = trailer.byteslice(eocd_offset + 20, 2).unpack1("v")
      next false unless eocd_offset + 22 + comment_length == trailer.bytesize

      zip_matches_snapshot?(file, source_root)
    end
  rescue Errno::ENOENT, Zip::Error, EncodingError, ArgumentError, EOFError, IOError
    false
  end

  def zip_matches_snapshot?(file, source_root)
    expected = source_root.entries.map do |relative, manifest|
      name = safe_entry_name(relative, directory: manifest[2] == :directory)
      [ name, manifest[2], manifest[2] == :file ? manifest[3] : 0 ]
    end.sort

    file.rewind
    matches = false
    Zip::File.open_buffer(file) do |archive|
      return false if archive.entries.size > MAX_ARCHIVE_ENTRIES

      actual = archive.entries.map do |entry|
        enforce_runtime_budget!
        type = entry.directory? ? :directory : :file
        [ entry.name, type, type == :file ? entry.size : 0 ]
      end.sort
      matches = actual == expected
    end
    matches
  end

  def with_build_admission
    deadline = monotonic_time + archive_admission_wait_seconds
    paths = self.class.admission_lock_paths(directory: CACHE_DIRECTORY)
    offset = Integer(@book.id) % paths.length

    loop do
      enforce_runtime_budget!
      paths.rotate(offset).each do |path|
        acquired = false
        result = FileCopyService.with_private_lock(
          path,
          root: CACHE_DIRECTORY.to_s,
          nonblock: true
        ) do
          acquired = true
          enforce_runtime_budget!
          yield
        end
        return result if acquired
      end

      now = monotonic_time
      raise BusyError, "archive build capacity is temporarily exhausted" if now >= deadline

      pause_before_admission_retry([ archive_admission_retry_seconds, deadline - now ].min)
    end
  end

  def with_cache_coordination
    deadline = monotonic_time + archive_coordination_wait_seconds
    path = self.class.lock_path_for_book(@book.id, directory: CACHE_DIRECTORY)

    loop do
      enforce_runtime_budget!
      acquired = false
      result = FileCopyService.with_private_lock(
        path,
        root: CACHE_DIRECTORY.to_s,
        nonblock: true
      ) do
        acquired = true
        enforce_runtime_budget!
        yield
      end
      return result if acquired

      now = monotonic_time
      raise BusyError, "archive cache coordination is temporarily unavailable" if now >= deadline

      pause_before_admission_retry([ archive_admission_retry_seconds, deadline - now ].min)
    end
  end

  def start_runtime_budget!
    @runtime_deadline = monotonic_time + max_archive_runtime_seconds
  end

  def enforce_runtime_budget!
    return unless @runtime_deadline
    return if monotonic_time <= @runtime_deadline

    raise ResourceLimitError, "library archive exceeded its processing time budget"
  end

  def enforce_output_budget!(output)
    return if output.stat.size <= max_archive_output_bytes

    raise ResourceLimitError, "library archive output exceeds its byte budget"
  end

  def pause_before_admission_retry(seconds)
    sleep(seconds)
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def max_archive_source_bytes
    MAX_ARCHIVE_SOURCE_BYTES
  end

  def max_archive_output_bytes
    MAX_ARCHIVE_OUTPUT_BYTES
  end

  def max_archive_name_bytes
    MAX_ARCHIVE_NAME_BYTES
  end

  def max_archive_runtime_seconds
    MAX_ARCHIVE_RUNTIME_SECONDS
  end

  def archive_admission_wait_seconds
    MAX_ARCHIVE_ADMISSION_WAIT_SECONDS
  end

  def archive_coordination_wait_seconds
    MAX_ARCHIVE_COORDINATION_WAIT_SECONDS
  end

  def archive_admission_retry_seconds
    ARCHIVE_ADMISSION_RETRY_SECONDS
  end
end
