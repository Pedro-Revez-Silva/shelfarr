# frozen_string_literal: true

require "digest"
require "pathname"
require "zlib"

# Descriptor-relative extraction for direct-download audiobook ZIP archives.
# The source is an already-open private staging descriptor and every output is
# created beneath a pinned staging root. Archive metadata can therefore never
# create links/special files or redirect writes after an ancestor path swap.
class DirectDownloadArchiveExtractor
  MAX_ENTRY_PATH_BYTES = 1_024
  MAX_ENTRY_COMPONENT_BYTES = 255
  MAX_ENTRY_DEPTH = 32
  MAX_CENTRAL_DIRECTORY_BYTES = 16.megabytes
  MAX_TOTAL_PATH_BYTES = 8.megabytes
  MAX_COMPRESSION_RATIO = 100
  MAX_TREE_ENTRY_FACTOR = 2
  HEARTBEAT_INTERVAL = 10.seconds
  DEFAULT_MAX_DURATION = 10.minutes

  class Error < StandardError; end

  def initialize(
    source:,
    destination:,
    output_root:,
    max_bytes:,
    max_entries:,
    heartbeat: nil,
    allowed_file_extensions: nil,
    max_duration: DEFAULT_MAX_DURATION
  )
    @source = source
    @destination = Pathname(destination).expand_path
    @output_root = Pathname(output_root).expand_path
    @max_bytes = max_bytes.to_i
    @max_entries = max_entries.to_i
    @heartbeat = heartbeat
    @allowed_file_extensions = Array(allowed_file_extensions).map { |extension| extension.to_s.downcase }.presence
    @max_duration = max_duration.to_f
  end

  def extract!
    require "zip"

    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @max_duration
    validate_source!
    ZipArchivePreflightService.validate!(
      @source,
      max_entries: @max_entries,
      max_central_directory_bytes: MAX_CENTRAL_DIRECTORY_BYTES,
      max_uncompressed_bytes: @max_bytes,
      max_compression_ratio: MAX_COMPRESSION_RATIO
    )
    Zip::File.open(descriptor_path) do |archive|
      entries = validated_entries(archive.entries)
      total_bytes = 0
      extracted_files = 0

      entries.each do |entry, relative, type|
        pulse!
        if type == :directory
          FileCopyService.ensure_private_relative_directory(
            @destination,
            relative,
            root: @output_root
          )
          next
        end

        FileCopyService.with_private_file_noreplace(
          @destination,
          relative,
          root: @output_root
        ) do |output|
          entry_bytes = 0
          entry_crc = 0
          entry.get_input_stream do |input|
            buffer = +""
            while (chunk = input.read(FileCopyService::BUFFER_SIZE, buffer))
              next if chunk.empty?

              pulse!
              total_bytes += chunk.bytesize
              entry_bytes += chunk.bytesize
              if total_bytes > @max_bytes
                raise Error,
                  "ZIP archive exceeds extracted size limit of #{@max_bytes / 1.megabyte} MB"
              end
              if entry_bytes > entry.size
                raise Error, "ZIP archive entry exceeds its declared size: #{entry_label(entry.name)}"
              end

              entry_crc = Zlib.crc32(chunk, entry_crc)
              output.write(chunk)
            end
          end
          unless entry_bytes == entry.size && entry_crc == entry.crc
            raise Error, "ZIP archive entry failed size or CRC validation: #{entry_label(entry.name)}"
          end
        end
        extracted_files += 1
      end

      raise Error, "ZIP archive did not contain any files" if extracted_files.zero?
    end
    validate_source!
    true
  rescue Zip::Error, ZipArchivePreflightService::Error => error
    raise Error, "Failed to extract audiobook archive: #{error.message}"
  rescue FileCopyService::UnsafePathError, SystemCallError => error
    raise Error, "Failed to extract audiobook archive safely: #{error.message}"
  ensure
    @source.rewind if @source.respond_to?(:rewind) && !@source.closed?
  end

  private

  def validate_source!
    stat = @source.stat
    raise Error, "Downloaded ZIP is not a regular file" unless stat.file?

    identity = [ stat.dev, stat.ino, stat.size ]
    digest = digest_source
    if @source_identity
      unless identity == @source_identity && digest == @source_digest
        raise Error, "Downloaded ZIP changed during extraction"
      end
    else
      @source_identity = identity
      @source_digest = digest
    end
    @source.rewind
  end

  def digest_source
    digest = Digest::SHA256.new
    @source.rewind
    buffer = +""
    while @source.read(FileCopyService::BUFFER_SIZE, buffer)
      pulse!
      digest.update(buffer)
    end
    digest.hexdigest
  end

  def descriptor_path
    linux_path = "/proc/self/fd/#{@source.fileno}"
    return linux_path if File.exist?(linux_path)

    "/dev/fd/#{@source.fileno}"
  end

  def validated_entries(entries)
    raise Error, "ZIP archive contains too many entries" if entries.size > @max_entries

    paths = {}
    tree_paths = {}
    total_path_bytes = 0
    entries.filter_map do |entry|
      type = archive_entry_type(entry)
      relative = normalize_entry_name(entry.name, directory: type == :directory)
      next if @allowed_file_extensions && type == :directory
      if @allowed_file_extensions && !@allowed_file_extensions.include?(File.extname(relative).delete(".").downcase)
        raise Error, "ZIP archive contains an unsupported file type: #{entry_label(entry.name)}"
      end
      if paths.key?(relative)
        raise Error, "ZIP archive contains a duplicate path: #{entry_label(entry.name)}"
      end
      paths[relative] = type
      components = relative.split("/")
      tree_path = +""
      components.each do |component|
        tree_path << "/" unless tree_path.empty?
        tree_path << component
        next if tree_paths.key?(tree_path)

        tree_paths[tree_path] = true
        total_path_bytes += tree_path.bytesize
        if tree_paths.size > @max_entries * MAX_TREE_ENTRY_FACTOR
          raise Error, "ZIP archive expands to too many files and directories"
        end
        if total_path_bytes > MAX_TOTAL_PATH_BYTES
          raise Error, "ZIP archive paths exceed their aggregate size limit"
        end
      end
      [ entry, relative, type ]
    end.tap do |validated|
      validated.each do |_entry, relative, _type|
        parts = relative.split("/")
        (1...parts.length).each do |length|
          ancestor = parts.first(length).join("/")
          if paths[ancestor] == :file
            raise Error, "ZIP archive contains conflicting paths: #{entry_label(relative)}"
          end
        end
      end
    end
  end

  def archive_entry_type(entry)
    if entry.symlink? || (!entry.directory? && !entry.file?)
      raise Error, "ZIP archive contains a symbolic link or special file: #{entry_label(entry.name)}"
    end

    entry.directory? ? :directory : :file
  end

  def normalize_entry_name(name, directory:)
    value = name.to_s.dup
    value.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::ASCII_8BIT
    raise Error, "ZIP archive contains an unsafe path: #{entry_label(name)}" unless value.valid_encoding?

    value = value.delete_suffix("/") if directory
    segments = value.split("/", -1)
    unsafe = !value.valid_encoding? || value.blank? || value.start_with?("/", "\\") ||
      value.include?("\\") || value.include?("\0") || value.bytesize > MAX_ENTRY_PATH_BYTES ||
      segments.size > MAX_ENTRY_DEPTH || segments.any? do |segment|
        segment.blank? || segment.in?([ ".", ".." ]) ||
          segment.bytesize > MAX_ENTRY_COMPONENT_BYTES || segment.match?(/[[:cntrl:]]/) ||
          segment.downcase.start_with?(".shelfarr")
      end
    raise Error, "ZIP archive contains an unsafe path: #{entry_label(name)}" if unsafe

    segments.join("/")
  end

  def entry_label(name)
    name.to_s.scrub("?").gsub(/[[:cntrl:]]/, "?").truncate(200)
  end

  def pulse!
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise Error, "ZIP archive extraction exceeded its time limit" if @deadline && now > @deadline
    return unless @heartbeat
    return if @last_heartbeat_at && now - @last_heartbeat_at < HEARTBEAT_INTERVAL.to_f

    @heartbeat.call
    @last_heartbeat_at = now
  end
end
