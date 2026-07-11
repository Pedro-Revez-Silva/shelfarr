# frozen_string_literal: true

# Builds a conservative, filesystem-only import plan for audiobook releases
# that contain one self-contained audio file per book. Chaptered and multipart
# releases deliberately fall back to the normal single-directory import.
class AudiobookBundleImportPlanner
  KNOWN_AUDIO_EXTENSIONS = %w[
    aa aac aax aaxc aiff alac flac m4a m4b mp3 ogg opus wav wma
  ].freeze
  SELF_CONTAINED_BOOK_EXTENSIONS = %w[aax m4b].freeze
  SIDECAR_EXTENSIONS = %w[bmp cue gif jpeg jpg nfo opf png txt webp].freeze
  GENERIC_COVER_STEMS = %w[artwork cover folder front thumbnail].freeze
  NUMBER_WORD_PATTERN = /(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)/i
  PART_MARKER_PATTERN = /\b(?:part|disc|disk|cd|track|chapter|volume|vol|side)\s*(?:\d+|#{NUMBER_WORD_PATTERN}|[a-z]|[ivxlcdm]+)(?:\s+of\s+\d+)?\z/i
  LEADING_SEQUENCE_PATTERN = /\A\s*\d{1,3}(?:\s*[-._]\s*|\s+)\S/
  TRAILING_SEQUENCE_PATTERN = /(?:\s+(?:[-._]\s*)?|[._])\d{1,3}\s*\z/
  TRAILING_TITLE_QUALIFIER_PATTERN = /(?:\s*(?:\([^()]+\)|\[[^\[\]]+\]))+\s*\z/

  class UnsafeDestinationError < StandardError; end

  Entry = Data.define(:source_path, :virtual_book, :destination, :sidecar_paths)
  Plan = Data.define(:entries, :tracked_entry, :unassigned_paths)

  def self.call(...)
    new(...).call
  end

  def initialize(source:, book:, base_path:)
    @source = source
    @book = book
    @base_path = base_path
  end

  def call
    return unless book&.audiobook? && File.directory?(source)

    paths = immediate_source_paths
    return if paths.empty?
    return if paths.any? { |path| File.symlink?(path) || File.directory?(path) || !File.file?(path) }

    audio_paths = paths.select { |path| audio_file?(path) }
    return unless audio_paths.many?
    return unless audio_paths.all? { |path| self_contained_book_file?(path) }

    entries = audio_paths.sort_by { |path| File.basename(path).downcase }.map { |path| build_entry(path) }
    return unless distinct_book_titles?(entries)
    return if likely_multipart_release?(entries)

    tracked_entry = tracked_entry_for(entries)
    return unless tracked_entry

    entries = preserve_tracked_metadata(entries, tracked_entry)
    return unless destinations_disjoint?(entries)
    validate_destinations_outside_source!(entries)

    entries = assign_sidecars(entries, paths)
    assigned_paths = entries.flat_map(&:sidecar_paths).uniq
    unassigned_paths = paths - audio_paths - assigned_paths
    tracked_entry = entries.find { |entry| entry.source_path == tracked_entry.source_path }

    Plan.new(entries: entries, tracked_entry: tracked_entry, unassigned_paths: unassigned_paths)
  end

  private

  attr_reader :source, :book, :base_path

  def immediate_source_paths
    Dir.children(source).map { |entry| File.join(source, entry) }
  end

  def build_entry(source_path)
    metadata = MetadataExtractorService.extract(source_path)
    virtual_book = build_virtual_book(source_path, metadata)

    Entry.new(
      source_path: source_path,
      virtual_book: virtual_book,
      destination: destination_for(virtual_book),
      sidecar_paths: []
    )
  end

  def build_virtual_book(source_path, metadata)
    virtual_book = book.dup
    virtual_book.assign_attributes(
      title: metadata.title.presence || title_from_filename(source_path),
      author: metadata.author.presence || book.author,
      year: metadata.year,
      narrator: metadata.narrator,
      publisher: nil,
      series_position: nil,
      file_path: nil
    )
    virtual_book
  end

  def title_from_filename(path)
    stem = File.basename(path, File.extname(path)).to_s.strip
    stem = stem.sub(/\A\d{1,3}\s*[-._]\s*/, "").strip
    return "Unknown" if stem.blank?

    parsed = FilenameParserService.parse(stem)
    if parsed.author.present? && normalized_title(parsed.author) == normalized_title(book.author)
      parsed.title.presence || stem
    else
      stem
    end
  end

  def destination_for(virtual_book)
    return PathTemplateService.build_destination(virtual_book, base_path: base_path) unless PathTemplateService.flat_output?(book)

    File.join(base_path, sanitize_path_segment(virtual_book.title))
  end

  def distinct_book_titles?(entries)
    titles = entries.map { |entry| normalized_title(entry.virtual_book.title) }
    titles.none?(&:blank?) && titles.uniq.size == entries.size
  end

  def likely_multipart_release?(entries)
    metadata_identities = entries.map { |entry| multipart_identity(entry.virtual_book.title) }
    return true if duplicate_identity?(metadata_identities)

    raw_stems = entries.map do |entry|
      File.basename(entry.source_path, File.extname(entry.source_path))
    end
    return true if raw_stems.count { |stem| stem.match?(/\A\s*\d+\s*\z/) } > 1

    raw_titles = raw_stems.map { |stem| normalized_title(stem) }
    raw_identities = raw_titles.map { |title| multipart_identity(title) }
    duplicate_raw_identity = duplicate_identity?(raw_identities)
    raw_multipart_evidence = raw_titles.any? { |title| title.match?(PART_MARKER_PATTERN) } ||
      raw_stems.any? { |stem| stem.match?(LEADING_SEQUENCE_PATTERN) || stem.match?(TRAILING_SEQUENCE_PATTERN) }
    return true if duplicate_raw_identity && raw_multipart_evidence

    requested_title = normalized_title(book.title)
    duplicate_raw_identity && raw_identities.include?(requested_title)
  end

  def duplicate_identity?(identities)
    identities.tally.any? { |_identity, count| count > 1 }
  end

  def multipart_identity(value)
    normalized_title(value)
      .sub(/\A\d+\s+/, "")
      .sub(PART_MARKER_PATTERN, "")
      .sub(/\s+\d+\s+of\s+\d+\z/, "")
      .sub(/\s+\d+\z/, "")
      .squish
  end

  def preserve_tracked_metadata(entries, tracked_entry)
    entries.map do |entry|
      next entry unless entry.source_path == tracked_entry.source_path

      virtual_book = entry.virtual_book
      virtual_book.assign_attributes(
        year: virtual_book.year || book.year,
        narrator: virtual_book.narrator.presence || book.narrator,
        publisher: virtual_book.publisher.presence || book.publisher,
        series_position: virtual_book.series_position.presence || book.series_position
      )

      Entry.new(
        source_path: entry.source_path,
        virtual_book: virtual_book,
        destination: destination_for(virtual_book),
        sidecar_paths: entry.sidecar_paths
      )
    end
  end

  def tracked_entry_for(entries)
    requested_title = normalized_title(book.title)
    return if requested_title.blank?

    exact_matches = entries.select { |entry| normalized_title(entry.virtual_book.title) == requested_title }
    return exact_matches.first if exact_matches.one?

    qualified_matches = entries.select do |entry|
      qualified_title_match?(entry.virtual_book.title, book.title)
    end
    qualified_matches.first if qualified_matches.one?
  end

  def qualified_title_match?(candidate, requested)
    candidate_title = normalized_title(candidate)
    requested_title = normalized_title(requested)
    candidate_base = normalized_title(strip_title_qualifier(candidate))
    requested_base = normalized_title(strip_title_qualifier(requested))

    requested_is_unqualified = requested_base == requested_title
    candidate_has_qualifier = candidate_base != candidate_title

    requested_is_unqualified && candidate_has_qualifier &&
      candidate_base.present? && candidate_base == requested_title
  end

  def strip_title_qualifier(value)
    value.to_s.sub(TRAILING_TITLE_QUALIFIER_PATTERN, "").strip
  end

  def assign_sidecars(entries, paths)
    companions = paths.reject { |path| audio_file?(path) }

    entries.map do |entry|
      source_stem = File.basename(entry.source_path, File.extname(entry.source_path)).downcase
      matching_sidecars = companions.select do |companion|
        companion_stem = File.basename(companion, File.extname(companion)).downcase
        companion_stem == source_stem || (sidecar_file?(companion) && GENERIC_COVER_STEMS.include?(companion_stem))
      end

      Entry.new(
        source_path: entry.source_path,
        virtual_book: entry.virtual_book,
        destination: entry.destination,
        sidecar_paths: matching_sidecars
      )
    end
  end

  def audio_file?(path)
    return true if KNOWN_AUDIO_EXTENSIONS.include?(extension_for(path))

    mime_type = File.open(path, "rb") do |file|
      Marcel::MimeType.for(file, name: File.basename(path))
    end
    mime_type.to_s.start_with?("audio/")
  rescue Errno::ENOENT, Errno::EACCES, IOError
    false
  end

  def self_contained_book_file?(path)
    SELF_CONTAINED_BOOK_EXTENSIONS.include?(extension_for(path))
  end

  def sidecar_file?(path)
    SIDECAR_EXTENSIONS.include?(extension_for(path))
  end

  def extension_for(path)
    File.extname(path).delete_prefix(".").downcase
  end

  def normalized_title(value)
    value.to_s.unicode_normalize(:nfkc).downcase(:fold).gsub(/[^[:alnum:]]+/, " ").squish
  end

  def sanitize_path_segment(value)
    value.to_s
      .unicode_normalize(:nfkc)
      .gsub(/[<>:"\/\\|?*]/, "")
      .gsub(/[\x00-\x1f]/, "")
      .squish
      .truncate(100, omission: "")
      .presence || "Unknown"
  end

  def destinations_disjoint?(entries)
    destinations = entries.map { |entry| canonical_path(entry.destination) }

    destinations.combination(2).none? do |first, second|
      path_within?(first, second) || path_within?(second, first)
    end
  end

  def validate_destinations_outside_source!(entries)
    source_path = canonical_path(source)
    overlapping_entry = entries.find do |entry|
      path_within?(canonical_path(entry.destination), source_path)
    end
    return unless overlapping_entry

    raise UnsafeDestinationError,
      "Cannot split audiobook bundle because a destination overlaps the download source directory"
  end

  def path_within?(candidate, parent)
    candidate = normalized_path_key(candidate)
    parent = normalized_path_key(parent)
    prefix = parent.end_with?(File::SEPARATOR) ? parent : "#{parent}#{File::SEPARATOR}"
    candidate == parent || candidate.start_with?(prefix)
  end

  def normalized_path_key(path)
    path.to_s.unicode_normalize(:nfkc).downcase(:fold)
  end

  # Resolve symlinks in the existing portion of a path while retaining any
  # not-yet-created destination segments.
  def canonical_path(path)
    expanded_path = File.expand_path(path)
    existing_path = expanded_path
    missing_segments = []

    until File.exist?(existing_path) || File.symlink?(existing_path)
      parent = File.dirname(existing_path)
      break if parent == existing_path

      missing_segments.unshift(File.basename(existing_path))
      existing_path = parent
    end

    File.join(File.realpath(existing_path), *missing_segments)
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    expanded_path
  end
end
