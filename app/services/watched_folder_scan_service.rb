# frozen_string_literal: true

# Scans the configured watched-folder import path for book files that were not
# acquired through a Shelfarr request and records each new one as a
# DetectedImport awaiting admin review. Read-only with respect to the watched
# folder — it never moves, renames, or deletes source files.
#
# The walk uses FileCopyService's pinned, no-follow directory primitives so a
# symlink or a mid-scan path swap can never redirect it outside the configured
# root. Candidates are grouped the same way the download importer sees releases:
# a single ebook/comic file, a self-contained audiobook folder, or — for a box
# set / collection whose subfolders each hold a distinct title — one audiobook
# per subfolder (see #classify_directory).
class WatchedFolderScanService
  MAX_DEPTH = 8
  AUDIO_SEARCH_DEPTH = 4
  MAX_CANDIDATES_PER_SCAN = 5_000

  # Subfolder names that denote a disc/part of one audiobook rather than a
  # distinct title: "CD1", "Disc 2", "Part 03", "Vol 1", "Tape 2", or a bare
  # "1"/"01". Such folders must be kept together as a single multi-disc book,
  # never split into separate books the way a titled subfolder is.
  DISC_SUBFOLDER = /\A(?:(?:cd|dis[ck]|part|pt|vol(?:ume)?|section|tape|track)[\s._-]*)?\d{1,3}\z/i

  Candidate = Struct.new(
    :source_path,
    :book_type,
    :device,
    :inode,
    :filename_hint,
    :metadata_path,
    keyword_init: true
  )

  Result = Data.define(:scanned, :detected, :skipped)

  def self.scan!
    new.scan!
  end

  # Returns a Result summarising the scan, or nil when scanning is disabled or
  # the configured path is invalid.
  def scan!
    return nil unless SettingsService.get(:library_import_enabled, default: false)

    root = resolved_root
    unless root
      Rails.logger.warn "[WatchedFolderScanService] Watched-folder import path is unset or invalid; skipping scan"
      return nil
    end

    candidates = build_candidates(root)
    detected = 0
    candidates.each do |candidate|
      detected += 1 if record_candidate(candidate)
    end

    NotificationService.import_detected(count: detected) if detected.positive?
    Rails.logger.info(
      "[WatchedFolderScanService] Scan complete: #{candidates.size} candidates, #{detected} new"
    )
    Result.new(scanned: candidates.size, detected: detected, skipped: candidates.size - detected)
  end

  private

  # --- Filesystem walk -----------------------------------------------------

  def build_candidates(root)
    candidates = []
    walk(root, root, 0, candidates)
    candidates
  end

  def walk(dir, root, depth, candidates)
    return if depth > MAX_DEPTH
    return if candidates.size >= MAX_CANDIDATES_PER_SCAN

    FileCopyService.directory_children(dir, root: root).each do |child|
      break if candidates.size >= MAX_CANDIDATES_PER_SCAN
      next if child.name.start_with?(".")

      path = File.join(dir, child.name)
      case child.type
      when :file
        candidates << file_candidate(path, child) if LibraryAcquisitionService.readable_file?(child.name)
        # Loose audio files directly under a directory become part of that
        # directory's audiobook candidate (below), never standalone imports.
      when :directory
        classify_directory(path, child, root, depth, candidates)
      end
    end
  rescue FileCopyService::UnsafePathError, SystemCallError => e
    Rails.logger.warn "[WatchedFolderScanService] Skipping unreadable directory (#{e.class})"
  end

  # Resolve how one directory maps onto audiobook candidates. Three shapes look
  # alike from the top and have to be told apart:
  #
  #   * plain audiobook   Book/*.mp3              -> one candidate (this folder)
  #   * multi-disc book   Book/CD1/*.mp3, ...     -> one candidate (this folder)
  #   * collection/set    Set/Title A/*.mp3, ...  -> one candidate PER subfolder
  #
  # The signal is where the audio lives. Loose audio directly in the folder
  # means the folder itself is the release. Otherwise the audio sits in
  # subfolders: if those are all disc markers (CD1, Disc 2, ...) the folder is a
  # single multi-disc book; if any carries a real title the folder is a
  # collection, so we descend and each audio-bearing subfolder becomes its own
  # book (recursively — a nested subfolder may itself be multi-disc).
  def classify_directory(dir, child, root, depth, candidates)
    direct = direct_audio_file(dir, root)
    if direct
      candidates << audiobook_candidate(dir, child, direct)
      return
    end

    audio_subdirs = audio_bearing_subdirectories(dir, root)
    if audio_subdirs.empty?
      # No audio at any level yet: a plain intermediate folder — keep walking.
      walk(dir, root, depth + 1, candidates)
    elsif audio_subdirs.all? { |name| disc_subfolder?(name) }
      # Discs of one book: import the whole folder as a single audiobook.
      nested = first_audio_file(dir, root, 0)
      candidates << audiobook_candidate(dir, child, nested) if nested
    else
      # A collection: descend so each titled subfolder becomes its own book.
      walk(dir, root, depth + 1, candidates)
    end
  end

  # An audio file lying directly inside dir (not in any subfolder). Its presence
  # marks dir as a self-contained audiobook release rather than a container of
  # further releases.
  def direct_audio_file(dir, root)
    FileCopyService.directory_children(dir, root: root).each do |child|
      next if child.name.start_with?(".")

      if child.type == :file && LibraryAcquisitionService.audio_file?(child.name)
        return File.join(dir, child.name)
      end
    end
    nil
  rescue FileCopyService::UnsafePathError, SystemCallError
    nil
  end

  # Names of the immediate subdirectories of dir that contain audio somewhere in
  # their subtree. Empty when dir holds no nested audiobook material. Used to
  # decide whether dir is a multi-disc book or a collection of separate books.
  def audio_bearing_subdirectories(dir, root)
    FileCopyService.directory_children(dir, root: root).filter_map do |child|
      next if child.name.start_with?(".")
      next unless child.type == :directory

      child.name if first_audio_file(File.join(dir, child.name), root, 0)
    end
  rescue FileCopyService::UnsafePathError, SystemCallError
    []
  end

  def disc_subfolder?(name)
    DISC_SUBFOLDER.match?(name.to_s.strip)
  end

  # Bounded search for the first playable audio file within a directory subtree.
  # Its presence marks the directory as a single audiobook release.
  def first_audio_file(dir, root, depth)
    return nil if depth > AUDIO_SEARCH_DEPTH

    children = FileCopyService.directory_children(dir, root: root)
    children.each do |child|
      next if child.name.start_with?(".")

      if child.type == :file && LibraryAcquisitionService.audio_file?(child.name)
        return File.join(dir, child.name)
      end
    end
    children.each do |child|
      next if child.name.start_with?(".")
      next unless child.type == :directory

      found = first_audio_file(File.join(dir, child.name), root, depth + 1)
      return found if found
    end
    nil
  rescue FileCopyService::UnsafePathError, SystemCallError
    nil
  end

  def file_candidate(path, child)
    Candidate.new(
      source_path: path,
      book_type: LibraryAcquisitionService.infer_book_type(path),
      device: reliable_identity(child.device),
      inode: reliable_identity(child.inode),
      filename_hint: File.basename(path),
      metadata_path: path
    )
  end

  def audiobook_candidate(path, child, audio_path)
    Candidate.new(
      source_path: path,
      book_type: "audiobook",
      device: reliable_identity(child.device),
      inode: reliable_identity(child.inode),
      filename_hint: File.basename(path),
      metadata_path: audio_path
    )
  end

  # Some filesystems (certain FUSE/network/overlay mounts) report a device or
  # inode of 0 for every entry. A non-positive value is not a usable identity —
  # keeping it would collapse unrelated files onto one (device, inode) key and
  # make de-duplication drop all but the first file per device. Discard it so
  # known? falls back to path-based de-duplication instead.
  def reliable_identity(value)
    value.to_i.positive? ? value.to_i : nil
  end

  # --- Persistence ---------------------------------------------------------

  # Returns true when a new DetectedImport was created.
  def record_candidate(candidate)
    return false if known?(candidate)

    # Local-only identification (metadata extract + library match). The online
    # provider lookups are deferred to DetectedImportEnrichmentJob so a large
    # first scan never fires thousands of sequential network searches inside a
    # single run (which would also hold the scan's concurrency lease and stall
    # the recurring chain).
    identification = LibraryAcquisitionService.identify(
      source_path: candidate.metadata_path,
      book_type: candidate.book_type,
      filename_hint: candidate.filename_hint,
      online: false
    )

    detected_import = DetectedImport.create!(
      source_path: candidate.source_path,
      source_device: candidate.device,
      source_inode: candidate.inode,
      book_type: identification.book_type,
      parsed_title: identification.parsed_title,
      parsed_author: identification.parsed_author,
      match_confidence: identification.match_confidence,
      suggested_book: identification.suggested_book,
      candidate_books: identification.candidate_books,
      status: "detected",
      detected_at: Time.current
    )
    DetectedImportEnrichmentJob.perform_later(detected_import.id)
    true
  rescue ActiveRecord::RecordNotUnique
    # A concurrent scan already recorded this (device, inode).
    false
  rescue => e
    Rails.logger.error "[WatchedFolderScanService] Failed to record candidate (#{e.class})"
    false
  end

  def known?(candidate)
    if candidate.device && candidate.inode
      return true if DetectedImport.where(source_device: candidate.device, source_inode: candidate.inode).exists?
    elsif DetectedImport.where(source_path: candidate.source_path).exists?
      # No reliable (device, inode) identity available — de-duplicate on the
      # source path instead, so files on inode-less filesystems still surface
      # exactly once.
      return true
    end

    Book.acquired.where(file_path: candidate.source_path).exists?
  end

  # --- Path validation -----------------------------------------------------

  def resolved_root
    raw = SettingsService.get(:library_import_path).to_s.strip
    return nil if raw.blank?

    expanded = File.expand_path(raw)
    return nil unless File.directory?(expanded)

    canonical = File.realpath(expanded)
    return nil if Pathname(canonical).root?
    return nil if overlaps_output_paths?(canonical)

    canonical
  rescue ArgumentError, SystemCallError
    nil
  end

  # Refuse a watched path that is the same as, inside, or a parent of any
  # configured output path — otherwise Shelfarr would re-detect its own imports.
  def overlaps_output_paths?(canonical)
    output_roots.any? do |output|
      output == canonical || path_inside?(canonical, output) || path_inside?(output, canonical)
    end
  end

  def output_roots
    [
      SettingsService.get(:audiobook_output_path, default: "/audiobooks"),
      SettingsService.get(:ebook_output_path, default: "/ebooks"),
      SettingsService.get(:comicbook_output_path, default: "/comics")
    ].filter_map { |path| canonical_directory(path) }.uniq
  end

  def canonical_directory(path)
    expanded = File.expand_path(path.to_s)
    return nil unless File.directory?(expanded)

    File.realpath(expanded)
  rescue ArgumentError, SystemCallError
    nil
  end

  def path_inside?(path, root)
    path.start_with?("#{root}#{File::SEPARATOR}")
  end
end
