# frozen_string_literal: true

# Publishes a source file or directory into the organised library using the
# configured import mode (copy / move / hardlink), reusing FileCopyService's
# atomic, no-replace, TOCTOU-safe primitives — the same ones PostProcessingJob
# uses for request downloads. Only the mode dispatch and traversal live here;
# every actual filesystem publication goes through FileCopyService so the hard
# safety guarantees are shared, not re-implemented.
#
# Single files are renamed with the book's filename template. Directory imports
# (multi-file audiobooks) preserve the source layout and filenames. The source
# is never mutated except by an explicit "move", which FileCopyService performs
# only after a durable publication.
class LibraryFileImporter
  MODES = %w[copy move hardlink].freeze

  Result = Data.define(:imported_path, :hardlinked, :copied, :moved)

  def initialize(mode:)
    @mode = MODES.include?(mode.to_s) ? mode.to_s : "copy"
    @hardlinked = 0
    @copied = 0
    @moved = 0
  end

  # Import +source+ into the library for +book+, rooted at +base_path+ (the
  # book type's output root). Returns a Result whose imported_path is the file
  # (flat output / single file) or the per-book directory.
  def import(source:, book:, base_path:)
    source = File.expand_path(source.to_s)
    raise Errno::ENOENT, source unless File.exist?(source)

    stat = File.lstat(source)
    raise "Refusing to import symbolic link: #{source}" if stat.symlink?

    @root = Pathname(base_path).expand_path
    destination_dir = PathTemplateService.build_destination(book, base_path: @root.to_s)

    imported_path =
      if stat.directory?
        import_directory(source, destination_dir)
        destination_dir
      elsif stat.file?
        import_single_file(source, destination_dir, book)
      else
        raise "Refusing to import non-regular path: #{source}"
      end

    Result.new(imported_path: imported_path, hardlinked: @hardlinked, copied: @copied, moved: @moved)
  end

  private

  def import_single_file(source, destination_dir, book)
    FileCopyService.ensure_directory(destination_dir, root: @root, mode: 0o750)
    filename = PathTemplateService.build_filename(book, File.extname(source))
    destination_file = File.join(destination_dir, filename)
    imported = publish(source, destination_file, source_root: nil)

    PathTemplateService.flat_output?(book) ? imported : destination_dir
  end

  def import_directory(source, destination_dir)
    @source_root = FileCopyService.snapshot_source_root(source)
    FileCopyService.ensure_directory(destination_dir, root: @root, mode: 0o750)
    import_tree(source, destination_dir)
  end

  def import_tree(source_dir, destination_dir)
    manifest_children(source_dir).each do |name|
      source_path = File.join(source_dir, name)
      stat = File.lstat(source_path)

      if stat.directory?
        nested = File.join(destination_dir, name)
        FileCopyService.ensure_directory(nested, root: @root, mode: 0o750)
        import_tree(source_path, nested)
      elsif stat.file?
        publish(source_path, File.join(destination_dir, name), source_root: @source_root)
      end
      # Non-regular entries are absent from the immutable manifest and skipped.
    end
  end

  # Enumerate a directory's children from the immutable source snapshot rather
  # than a fresh readdir, so a mid-import path swap cannot introduce new entries.
  # The snapshot is grouped by parent directory once (see children_by_parent) so
  # a deep tree costs O(entries) total instead of O(entries) per directory.
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

  # Publish one regular file with the configured mode, retrying under a numbered
  # filename when a concurrent writer claims the exclusive destination.
  def publish(source, destination, source_root:)
    original = destination
    counter = 1

    begin
      destination = unique_destination(original, counter)
      publish_with_mode(source, destination, source_root: source_root)
      destination
    rescue Errno::EEXIST
      counter += 1
      retry
    end
  end

  def publish_with_mode(source, destination, source_root:)
    case @mode
    when "move"
      FileCopyService.mv_noreplace(
        source, destination,
        root: @root, source_root: source_root, allow_compatibility_fallback: true
      )
      @moved += 1
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
        root: @root, source_root: source_root, allow_compatibility_fallback: true
      )
      @copied += 1
    end
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
