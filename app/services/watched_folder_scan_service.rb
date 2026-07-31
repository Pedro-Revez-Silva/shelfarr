# frozen_string_literal: true

# Scans the configured watched-folder import path for book files not acquired
# through a Shelfarr request, recording each new one as a DetectedImport awaiting
# review. Read-only: it never moves, renames, or deletes source files.
#
# The walk uses FileCopyService's pinned, no-follow primitives, so a symlink or a
# mid-scan path swap cannot redirect it outside the configured root. Candidates
# are grouped the way the download importer sees releases: a single ebook/comic
# file, a self-contained audiobook folder, or one audiobook per subfolder for a
# collection (see #classify_directory).
class WatchedFolderScanService
  MAX_DEPTH = 8
  AUDIO_SEARCH_DEPTH = 4
  MAX_CANDIDATES_PER_SCAN = 5_000

  # Subfolder names denoting a disc/part of one audiobook rather than a distinct
  # title ("CD1", "Disc 2", "Part 03", "Vol 1", a bare "01"). These stay together
  # as one multi-disc book instead of splitting like a titled subfolder.
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

  # Accumulator for one walk: how many candidates it examined, and those not
  # already accounted for by a detection or an acquired book.
  Walk = Struct.new(:candidates, :scanned, keyword_init: true)

  def self.scan!
    new.scan!
  end

  # Where embedded metadata should be read from: the source itself for a single
  # file, or the first playable audio file inside an audiobook folder — the same
  # one the scan picked. Used by the review page's Re-match so it reads what the
  # scanner read. Falls back to the source when the folder holds no audio.
  def self.metadata_path_for(source_path)
    new.metadata_path_for(source_path)
  end

  def metadata_path_for(source_path)
    return source_path unless File.directory?(source_path)

    first_audio_file(source_path, source_path, 0) || source_path
  rescue SystemCallError
    source_path
  end

  # The canonical watched-folder root, or nil when the configured path is unset,
  # missing, or overlaps an output path. An import records it so undoing a move
  # can rebuild the source's parents and return the file through descriptors
  # pinned to this root, rather than a mutable parent path.
  def self.import_root
    new.resolved_root
  end

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

  # Returns a Result summarising the scan, or nil when scanning is disabled or
  # the configured path is invalid.
  def scan!
    return nil unless SettingsService.get(:library_import_enabled, default: false)

    root = resolved_root
    unless root
      Rails.logger.warn "[WatchedFolderScanService] Watched-folder import path is unset or invalid; skipping scan"
      return nil
    end

    walked = build_candidates(root)
    detected = walked.candidates.count { |candidate| record_candidate(candidate) }

    NotificationService.import_detected(count: detected) if detected.positive?
    Rails.logger.info(
      "[WatchedFolderScanService] Scan complete: #{walked.scanned} candidates, #{detected} new"
    )
    Result.new(scanned: walked.scanned, detected: detected, skipped: walked.scanned - detected)
  end

  private

  # --- Filesystem walk -----------------------------------------------------

  def build_candidates(root)
    walked = Walk.new(candidates: [], scanned: 0)
    walk(root, root, 0, walked)
    walked
  end

  def walk(dir, root, depth, walked)
    return if depth > MAX_DEPTH
    return if capped?(walked)

    # The rescue below stays despite visible_children having its own: it also
    # covers the loop body, where collect -> known? and the nested classification
    # raise the same errors and must skip this directory, not abort the scan.
    visible_children(dir, root).each do |child|
      break if capped?(walked)

      path = File.join(dir, child.name)
      case child.type
      when :file
        collect(walked, file_candidate(path, child)) if LibraryAcquisitionService.readable_file?(child.name)
        # Loose audio files directly under a directory become part of that
        # directory's audiobook candidate (below), never standalone imports.
      when :directory
        classify_directory(path, child, root, depth, walked)
      end
    end
  rescue FileCopyService::UnsafePathError, SystemCallError => e
    Rails.logger.warn "[WatchedFolderScanService] Abandoning directory mid-walk (#{e.class})"
  end

  # One directory's entries minus dotfiles, through FileCopyService's pinned
  # no-follow listing. An unreadable directory yields nothing, so the walk steps
  # over it instead of failing the scan.
  def visible_children(dir, root)
    FileCopyService.directory_children(dir, root: root).reject { |child| child.name.start_with?(".") }
  rescue FileCopyService::UnsafePathError, SystemCallError => e
    Rails.logger.warn "[WatchedFolderScanService] Skipping unlistable directory (#{e.class})"
    []
  end

  # Set aside a candidate the scan has not accounted for yet. Known ones are
  # filtered here rather than at record time so they cost nothing against the
  # cap: a copy or hardlink import never consumes its source, so a folder over
  # MAX_CANDIDATES_PER_SCAN would otherwise re-walk the same already-imported
  # first 5,000 every scan, and the files past them would never be detected.
  def collect(walked, candidate)
    walked.scanned += 1
    walked.candidates << candidate unless known?(candidate)
  end

  def capped?(walked)
    walked.candidates.size >= MAX_CANDIDATES_PER_SCAN
  end

  # Resolve how one directory maps onto audiobook candidates. Three shapes look
  # alike from the top:
  #
  #   * plain audiobook   Book/*.mp3              -> one candidate (this folder)
  #   * multi-disc book   Book/CD1/*.mp3, ...     -> one candidate (this folder)
  #   * collection/set    Set/Title A/*.mp3, ...  -> one candidate PER subfolder
  #
  # The signal is where the audio lives. Loose audio directly in the folder means
  # the folder is the release. Otherwise it sits in subfolders: all disc markers
  # means one multi-disc book; any real title means a collection, so we descend
  # and each audio-bearing subfolder becomes its own book (recursively, since a
  # nested subfolder may itself be multi-disc).
  def classify_directory(dir, child, root, depth, walked)
    direct = direct_audio_file(dir, root)
    if direct
      collect(walked, audiobook_candidate(dir, child, direct))
      return
    end

    audio_subdirs = audio_bearing_subdirectories(dir, root)
    if audio_subdirs.empty?
      # No audio at any level yet: a plain intermediate folder — keep walking.
      walk(dir, root, depth + 1, walked)
    elsif audio_subdirs.all? { |name| disc_subfolder?(name) }
      # Discs of one book: import the whole folder as a single audiobook.
      nested = first_audio_file(dir, root, 0)
      collect(walked, audiobook_candidate(dir, child, nested)) if nested
    else
      # A collection: descend so each titled subfolder becomes its own book.
      walk(dir, root, depth + 1, walked)
    end
  end

  # An audio file lying directly inside dir. Its presence marks dir as a
  # self-contained release rather than a container of further releases.
  def direct_audio_file(dir, root)
    audio_child(dir, visible_children(dir, root))
  end

  # The first playable audio file among an already-listed set of children.
  def audio_child(dir, children)
    child = children.find { |c| c.type == :file && LibraryAcquisitionService.audio_file?(c.name) }
    File.join(dir, child.name) if child
  end

  # Immediate subdirectories of dir holding audio anywhere in their subtree, used
  # to tell a multi-disc book from a collection of separate books.
  def audio_bearing_subdirectories(dir, root)
    visible_children(dir, root).filter_map do |child|
      next unless child.type == :directory

      child.name if first_audio_file(File.join(dir, child.name), root, 0)
    end
  end

  def disc_subfolder?(name)
    DISC_SUBFOLDER.match?(name.to_s.strip)
  end

  # Bounded search for the first playable audio file within a directory subtree.
  # Its presence marks the directory as a single audiobook release.
  def first_audio_file(dir, root, depth)
    return nil if depth > AUDIO_SEARCH_DEPTH

    children = visible_children(dir, root)
    direct = audio_child(dir, children)
    return direct if direct

    children.each do |child|
      next unless child.type == :directory

      found = first_audio_file(File.join(dir, child.name), root, depth + 1)
      return found if found
    end
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

  # Some FUSE/network/overlay mounts report device or inode 0 for every entry.
  # Keeping a non-positive value would collapse unrelated files onto one key and
  # make de-duplication drop all but the first file per device, so discard it and
  # let known? fall back to path-based de-duplication.
  def reliable_identity(value)
    value.to_i.positive? ? value.to_i : nil
  end

  # --- Persistence ---------------------------------------------------------

  # Persist a candidate the walk kept (already established as unknown). Returns
  # true when a new DetectedImport was created.
  def record_candidate(candidate)
    # Local-only identification (metadata extract + library match). Online
    # lookups are deferred to DetectedImportEnrichmentJob so a large first scan
    # never fires thousands of sequential searches inside one run, holding the
    # concurrency lease and stalling the recurring chain.
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
      claim = DetectedImport.find_by(source_device: candidate.device, source_inode: candidate.inode)
      if claim
        case identity_state(claim, candidate)
        when :match then return true
        when :absent then retire_stale_detection!(claim)
        else release_identity!(claim)
        end
      end
    elsif DetectedImport.where(source_path: candidate.source_path).exists?
      # No reliable (device, inode) identity available — de-duplicate on the
      # source path instead, so files on inode-less filesystems still surface
      # exactly once.
      return true
    end

    Book.acquired.where(file_path: candidate.source_path).exists?
  end

  # How a detection's (device, inode) claim relates to the candidate now carrying
  # that identity. The claim only means something while the file it was recorded
  # for still holds it: a move import consumes its source, and the filesystem may
  # then hand the inode to an unrelated file — which the unique index on the pair
  # would otherwise make permanently undetectable.
  #
  # In FileCopyService's vocabulary, read here as:
  #
  #   :match    - still the file it was recorded for, or a hardlink to it
  #   :absent   - the recorded path is gone: the identity travelled to the
  #               candidate's path (a rename keeps the inode) or was consumed
  #   :mismatch - a different file holds that path now, or it could not be read
  def identity_state(claim, candidate)
    return :match if claim.source_path == candidate.source_path

    FileCopyService.path_identity_state(
      claim.source_path, device: candidate.device, inode: candidate.inode
    )
  end

  # The source is gone from the recorded path while the same content is detected
  # under a new one, so the row can never be imported — it would fail on the dead
  # path — and nothing else prunes it. Left alone it sits in the queue forever
  # beside the row replacing it, so retire it.
  #
  # Rows past review get their identity released and nothing more: an "importing"
  # row is having its source consumed right now, an imported or dismissed row's
  # path records where the file came from rather than a target, and a row holding
  # a publication record needs it to reverse files an earlier attempt left behind.
  def retire_stale_detection!(claim)
    return release_identity!(claim) unless retirable?(claim)

    claim.destroy
    Rails.logger.info(
      "[WatchedFolderScanService] Retired detection ##{claim.id}: its source moved to another path"
    )
  rescue => e
    Rails.logger.warn "[WatchedFolderScanService] Could not retire a stale detection (#{e.class})"
    release_identity!(claim)
  end

  def retirable?(claim)
    DetectedImport::ACTIONABLE_STATUSES.include?(claim.status) && claim.publication_record.blank?
  end

  # Drop the stale claim so the inode's new occupant can be recorded under it.
  # update_columns because this is index bookkeeping, not a change worth
  # broadcasting to the review screens.
  def release_identity!(claim)
    claim.update_columns(source_device: nil, source_inode: nil, updated_at: Time.current)
  rescue => e
    Rails.logger.warn "[WatchedFolderScanService] Could not release stale source identity (#{e.class})"
  end

  # --- Path validation -----------------------------------------------------

  # Refuse a watched path equal to, inside, or a parent of any configured output
  # path — otherwise Shelfarr re-detects its own imports.
  def overlaps_output_paths?(canonical)
    output_roots.any? do |output|
      output == canonical || path_inside?(canonical, output) || path_inside?(output, canonical)
    end
  end

  def output_roots
    PathTemplateService.output_roots.filter_map { |path| canonical_directory(path) }.uniq
  end

  # The canonical form of an output path, which need not exist yet: on a first
  # run none of them do, and skipping those would let the scanner adopt a root it
  # is about to import into. So canonicalise the deepest existing ancestor and
  # re-attach the components below it — enough to compare against a canonical
  # root.
  def canonical_directory(path)
    expanded = File.expand_path(path.to_s)
    existing = expanded
    missing = []
    until File.directory?(existing)
      parent = File.dirname(existing)
      return nil if parent == existing

      missing.unshift(File.basename(existing))
      existing = parent
    end

    File.join(File.realpath(existing), *missing)
  rescue ArgumentError, SystemCallError
    nil
  end

  def path_inside?(path, root)
    path.start_with?("#{root}#{File::SEPARATOR}")
  end
end
