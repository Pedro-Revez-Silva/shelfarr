# frozen_string_literal: true

# Publishes a source file or directory into the organised library using the
# configured import mode (copy / move / hardlink), on FileCopyService's atomic,
# no-replace, TOCTOU-safe primitives — the same ones PostProcessingJob uses for
# request downloads. Only mode dispatch and traversal live here; every actual
# publication goes through FileCopyService, so the safety guarantees are shared
# rather than re-implemented.
#
# Single files are renamed with the book's filename template; directory imports
# (multi-file audiobooks) preserve the source layout. The source is never mutated
# except by an explicit "move", performed only after a durable publication.
#
# Every import is anchored on one immutable snapshot taken up front. The caller
# may pass the (device, inode) recorded at detection; publication is refused
# unless the snapshot still has that identity, so a source swapped between
# detection and approval cannot smuggle different bytes under an approved title.
#
# The result carries an exact record of what was published — every file created
# and every directory brought into existence — so a failed finalization or an
# admin undo reverses precisely this import instead of deleting a templated
# directory shared with other books.
class LibraryFileImporter
  MODES = %w[copy move hardlink].freeze

  class SourceIdentityMismatchError < StandardError; end
  # Raised when a multi-file release would have to be published into the output
  # root because the book type has no path template configured.
  class FlatOutputUnsupportedError < StandardError; end

  Result = Data.define(:imported_path, :hardlinked, :copied, :moved, :publication)

  def initialize(mode:)
    @mode = MODES.include?(mode.to_s) ? mode.to_s : "copy"
    @root = nil
    @source_base = nil
    @source_root = nil
    @source_snapshot = nil
    @hardlinked = 0
    @copied = 0
    @moved = 0
    @published_files = []
    @created_directories = []
  end

  # Import +source+ into the library for +book+, rooted at +base_path+ (the book
  # type's output root). imported_path is the file (flat output / single file) or
  # the per-book directory.
  #
  # expected_source_identity - optional [device, inode] from detection; nil skips
  #                            the check (filesystems with no usable inode).
  # source_base - the root the source was found under. Only recorded, never
  #               traversed here; undo needs it to return a moved file through
  #               descriptors pinned to that root.
  def import(source:, book:, base_path:, expected_source_identity: nil, source_base: nil)
    source = File.expand_path(source.to_s)
    raise Errno::ENOENT, source unless File.exist?(source)

    stat = File.lstat(source)
    raise "Refusing to import symbolic link: #{source}" if stat.symlink?

    @source_base = source_base.presence
    @root = Pathname(base_path).expand_path
    destination_dir = PathTemplateService.build_destination(book, base_path: @root.to_s)

    imported_path =
      if stat.directory?
        import_directory(source, destination_dir, book, expected_source_identity)
        destination_dir
      elsif stat.file?
        import_single_file(source, destination_dir, book, expected_source_identity)
      else
        raise "Refusing to import non-regular path: #{source}"
      end

    Result.new(
      imported_path: imported_path,
      hardlinked: @hardlinked,
      copied: @copied,
      moved: @moved,
      publication: publication_record
    )
  end

  # The exact, replayable description of what this import put on disk, ordered so
  # a reversal removes files first, then the directories it created, deepest
  # first. Readable after a failure too, so a caller can reverse a tree import
  # that raised partway through.
  def publication_record
    {
      "mode" => @mode,
      "base_path" => @root.to_s,
      "source_base" => @source_base,
      "files" => @published_files,
      "directories" => @created_directories
    }
  end

  private

  def import_single_file(source, destination_dir, book, expected_source_identity)
    @source_snapshot = FileCopyService.snapshot_source_file(source)
    verify_source_identity!(@source_snapshot.manifest.first(2), expected_source_identity, source)

    ensure_recorded_directory(destination_dir)
    filename = PathTemplateService.build_filename(book, File.extname(source))
    destination_file = File.join(destination_dir, filename)
    imported = publish(source, destination_file, source_root: nil)
    verify_hardlink_identity!(imported, expected_source_identity)

    PathTemplateService.flat_output?(book) ? imported : destination_dir
  end

  # A single-file hardlink re-resolves the source pathname inside FileCopyService,
  # so the approved inode is confirmed after the fact: a hardlink shares its
  # target's inode, and the caller reverses the publication on a mismatch. Tree
  # hardlinks are already pinned to the snapshot.
  def verify_hardlink_identity!(destination, expected_source_identity)
    return unless @mode == "hardlink" && @hardlinked.positive?

    published = @published_files.last
    return unless published && published["destination"] == destination

    verify_source_identity!(
      [ published["device"], published["inode"] ],
      expected_source_identity || @source_snapshot.manifest.first(2),
      destination
    )
  end

  def import_directory(source, destination_dir, book, expected_source_identity)
    # A blank path template writes straight into the output root, which a
    # multi-file release cannot survive: its tracks would scatter among every
    # other book and book.file_path would claim the root itself.
    # UploadZipImportFileService refuses the same configuration.
    if PathTemplateService.flat_output?(book)
      raise FlatOutputUnsupportedError,
        "Importing the folder #{File.basename(source)} requires a per-book path template for " \
        "#{book.book_type} output; set one in Settings and import again"
    end

    @source_root = FileCopyService.snapshot_source_root(source)
    verify_source_identity!([ @source_root.device, @source_root.inode ], expected_source_identity, source)

    ensure_recorded_directory(destination_dir)
    import_tree(source, destination_dir)
    consume_source_tree! if @mode == "move"
  end

  # A directory move publishes every file durably first, then unlinks the source
  # tree in one validated step. Removing each file as it was published would
  # invalidate the snapshot the remaining files are pinned against, failing the
  # import with the source already half-consumed.
  def consume_source_tree!
    unless FileCopyService.remove_source_tree(@source_root)
      raise Errno::ESTALE, "source tree changed during move import"
    end

    @moved = @copied
    @copied = 0
  end

  def import_tree(source_dir, destination_dir)
    manifest_children(source_dir).each do |name|
      source_path = File.join(source_dir, name)
      stat = File.lstat(source_path)

      if stat.directory?
        nested = File.join(destination_dir, name)
        ensure_recorded_directory(nested)
        import_tree(source_path, nested)
      elsif stat.file?
        publish(source_path, File.join(destination_dir, name), source_root: @source_root)
      end
      # Non-regular entries are absent from the immutable manifest and skipped.
    end
  end

  # Create +path+ under the output root, remembering the components that did not
  # exist beforehand. Only those may be removed on undo, and only while still
  # empty — a templated "Author/Book" directory is routinely shared with files
  # this import does not own.
  def ensure_recorded_directory(path)
    missing = missing_components(path)
    FileCopyService.ensure_directory(path, root: @root, mode: 0o750)

    missing.each do |created|
      identity = FileCopyService.directory_identity(created, root: @root)
      next unless identity

      @created_directories << { "path" => created, "device" => identity[0], "inode" => identity[1] }
    end
    path
  end

  def missing_components(path)
    relative = Pathname(path).expand_path.relative_path_from(@root)
    current = @root
    relative.each_filename.filter_map do |part|
      next if part == "."

      current = current.join(part)
      current.to_s unless exists?(current)
    end
  rescue ArgumentError
    []
  end

  def exists?(path)
    File.lstat(path)
    true
  rescue SystemCallError
    false
  end

  # Publish one regular file with the configured mode, retrying under a numbered
  # filename when a concurrent writer claims the exclusive destination.
  def publish(source, destination, source_root:)
    original = destination
    counter = 1
    # Read before publishing: a move unlinks the source, and undo needs its
    # identity to tell "still where the scanner found it" from "something
    # unrelated has taken over that path".
    source_identity = path_identity(source)

    begin
      destination = unique_destination(original, counter)
      publish_with_mode(source, destination, source_root: source_root)
    rescue Errno::EEXIST
      counter += 1
      retry
    end

    record_published_file(source, destination, source_identity)
    destination
  end

  def publish_with_mode(source, destination, source_root:)
    case @mode
    when "move"
      # A directory move defers source removal to consume_source_tree!, so the
      # per-file step is a durable copy against the pinned snapshot.
      if source_root
        FileCopyService.cp_noreplace(
          source, destination,
          root: @root, source_root: source_root,
          allow_compatibility_fallback: true, require_durable: true
        )
        @copied += 1
      else
        FileCopyService.mv_noreplace(
          source, destination,
          root: @root, source_root: nil, source_snapshot: @source_snapshot,
          allow_compatibility_fallback: true
        )
        @moved += 1
      end
    when "hardlink"
      begin
        FileCopyService.hardlink_noreplace(
          source, destination,
          root: @root, source_root: source_root
        )
        @hardlinked += 1
      rescue FileCopyService::HardlinkUnsupportedError
        FileCopyService.cp_noreplace(
          source, destination,
          root: @root, source_root: source_root,
          hardlink_mode: true, allow_compatibility_fallback: true
        )
        @copied += 1
      end
    else
      FileCopyService.cp_noreplace(
        source, destination,
        root: @root, source_root: source_root, source_snapshot: single_file_snapshot(source_root),
        allow_compatibility_fallback: true
      )
      @copied += 1
    end
  end

  # Single-file imports pin the snapshot taken (and identity-checked) up front;
  # tree imports are already pinned through the source root manifest.
  def single_file_snapshot(source_root)
    source_root ? nil : @source_snapshot
  end

  def record_published_file(source, destination, source_identity)
    entry = {
      "destination" => destination,
      "source" => source,
      "source_device" => source_identity&.first,
      "source_inode" => source_identity&.last
    }
    stat = File.lstat(destination)
    @published_files << entry.merge("device" => stat.dev, "inode" => stat.ino)
  rescue SystemCallError
    @published_files << entry
  end

  def path_identity(path)
    stat = File.lstat(path)
    [ stat.dev, stat.ino ]
  rescue SystemCallError
    nil
  end

  # Refuse to publish a source whose inode no longer matches the one recorded
  # when it was detected and approved.
  def verify_source_identity!(actual, expected, source)
    return if expected.nil?

    expected = Array(expected).map(&:to_i)
    return if expected.any?(&:zero?) || expected.size != 2
    return if actual.map(&:to_i) == expected

    raise SourceIdentityMismatchError,
      "Refusing to import #{source}: it is no longer the file that was detected and approved"
  end

  # A directory's children from the immutable snapshot rather than a fresh
  # readdir, so a mid-import path swap cannot introduce new entries. Grouped by
  # parent once (see children_by_parent), so a deep tree costs O(entries) total
  # instead of per directory.
  def manifest_children(directory)
    relative = Pathname(directory).expand_path.relative_path_from(@source_root.path)
    (children_by_parent[relative] || []).sort
  rescue ArgumentError
    []
  end

  # Index of parent directory (relative to the source root) => immediate child
  # basenames, built once per import from the immutable entry snapshot.
  def children_by_parent
    @children_by_parent ||= @source_root.entries.each_key.with_object({}) do |entry, index|
      path = Pathname(entry)
      (index[path.dirname] ||= []) << path.basename.to_s
    end.tap { |index| index.each_value(&:uniq!) }
  end

  def unique_destination(path, counter)
    return path if counter <= 1 && !occupied?(path)

    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)
    candidate = path
    while occupied?(candidate)
      candidate = File.join(dir, "#{base} (#{counter})#{ext}")
      counter += 1
    end
    candidate
  end

  def occupied?(path)
    File.exist?(path) || File.symlink?(path)
  end
end
