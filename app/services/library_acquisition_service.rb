# frozen_string_literal: true

# Shared "identify a book and import a source file into the organised library"
# engine for any front door adopting a file that was not acquired through a
# Shelfarr request (currently the watched-folder importer).
#
# The request pipeline still uses UploadProcessingJob / PostProcessingJob
# directly; this service reuses the same identification and path-template
# services, so both paths agree on structure and matching.
#
# +identify+ is read-only: a ranked suggestion, no Book created and no
# filesystem writes. +import!+ performs the crash-safe publication once an admin
# has approved a target Book.
class LibraryAcquisitionService
  # Audio containers that mark a file (or its folder) as an audiobook. Unlike
  # Upload::AUDIOBOOK_EXTENSIONS this excludes zip/rar archives, which are not
  # playable media in a completed-download folder.
  AUDIO_EXTENSIONS = %w[m4a m4b mp3 aax aac flac ogg opus wav].freeze
  # Single-file readable formats (ebooks + comics), reused from the download
  # importer so both front doors recognise the same types.
  READABLE_EXTENSIONS = PostProcessingJob::EBOOK_FILE_EXTENSIONS
  MAX_ONLINE_CANDIDATES = 5
  # Provider failures that are still a normal outcome: both candidate builders
  # degrade to an empty list, since human review is the correctness backstop.
  METADATA_ERRORS = [
    HardcoverClient::Error,
    GoogleBooksClient::Error,
    OpenLibraryClient::Error,
    MetadataService::Error
  ].freeze

  class AcquisitionConflictError < StandardError; end

  # Outcome of a successful import into the organised library.
  ImportResult = Data.define(:book, :destination_path, :mode, :publication)

  # What a retry found from an interrupted attempt: either a result to hand
  # straight back, or the source identity to import against once the stranded
  # publication has been reversed.
  Recovery = Data.define(:result, :reversed, :source_identity)

  # Read-only identification result. +candidate_books+ is a ranked array of plain
  # hashes, safe to persist as JSON on a DetectedImport.
  Identification = Data.define(
    :book_type,
    :parsed_title,
    :parsed_author,
    :suggested_book,
    :candidate_books,
    :match_confidence,
    :source_path
  )

  class << self
    # Inspect a source file and return a ranked suggestion. No writes.
    #
    # source_path   - regular file to read embedded metadata from; for an
    #                 audiobook folder, a representative audio file inside it.
    # book_type     - optional override; inferred from the path when omitted.
    # filename_hint - name for the filename-parse fallback (defaults to the
    #                 source basename; callers pass the folder name for an
    #                 audiobook so the parse reflects the release, not a track).
    def identify(source_path:, book_type: nil, filename_hint: nil, online: true)
      resolved_type = (book_type || infer_book_type(source_path)).to_s
      extracted = MetadataExtractorService.extract(source_path)
      parsed = FilenameParserService.parse(filename_hint.presence || File.basename(source_path.to_s))

      title = extracted.title.presence || parsed.title
      author = extracted.author.presence || parsed.author

      match = BookMatcherService.match(title: title, author: author, book_type: resolved_type)
      suggested_book = match.book if match.exact? || match.fuzzy?

      candidates = []
      candidates << library_candidate(match.book, match.score) if suggested_book
      candidates.concat(online_candidates(title, author, resolved_type)) if online

      confidence = if suggested_book
        match.score
      elsif extracted.present?
        90
      else
        parsed.confidence
      end

      Identification.new(
        book_type: resolved_type,
        parsed_title: title,
        parsed_author: author,
        suggested_book: suggested_book,
        candidate_books: candidates,
        match_confidence: confidence,
        source_path: source_path.to_s
      )
    end

    # Infer a book type from a path without reading it. A directory is treated
    # as an audiobook release; a file is classified by extension.
    def infer_book_type(source_path)
      return "audiobook" if File.directory?(source_path)

      case normalized_extension(source_path)
      when *Upload::COMICBOOK_EXTENSIONS then "comicbook"
      when *AUDIO_EXTENSIONS then "audiobook"
      else "ebook"
      end
    end

    # Import an already-decided book's source into the organised library, marking
    # the book acquired and triggering a library scan.
    #
    # source_path - file or directory to publish.
    # book        - target Book (must not already be acquired/reserved).
    # owner       - record holding the acquisition reservation for the duration
    #               of the import (e.g. a DetectedImport). Required so the
    #               reservation bridges the pre-import check and the file_path
    #               claim, as the upload path does.
    # mode        - copy / move / hardlink; defaults to the configured
    #               completed_download_import_mode.
    # source_identity - optional [device, inode] from detection. The importer
    #               refuses a source whose inode no longer matches, so a path
    #               swapped between approval and import cannot substitute bytes.
    # source_base - the root the source was found under, recorded so undo can
    #               restore a moved file through descriptors pinned to it.
    #
    # The publication record is persisted on +owner+ before the database claim:
    # bytes are on disk by then, and only an exact record of them makes a crash
    # or a lost claim race reversible.
    def import!(source_path:, book:, owner:, mode: nil, provenance: nil, source_identity: nil, source_base: nil)
      mode = (mode || SettingsService.get(:completed_download_import_mode, default: "copy")).to_s
      base_path = output_base_path(book)

      recovered = recover_interrupted_publication!(owner, book, source_identity)
      return recovered.result if recovered.result
      source_identity = recovered.source_identity if recovered.reversed

      reserve_book!(book, owner)
      importer = LibraryFileImporter.new(mode: mode)
      claimed = false
      begin
        result = importer.import(
          source: source_path,
          book: book,
          base_path: base_path,
          expected_source_identity: source_identity,
          source_base: source_base
        )
        record_publication!(owner, result.publication)

        claim_file_path!(book, result.imported_path, owner)
        # The import owns these bytes from here on; only an explicit undo
        # reverses them.
        claimed = true

        trigger_library_scan(book)
        Rails.logger.info(
          "[LibraryAcquisitionService] Imported #{provenance || 'source'} for book ##{book.id} (mode=#{mode})"
        )
        ImportResult.new(
          book: book,
          destination_path: result.imported_path,
          mode: mode,
          publication: result.publication
        )
      rescue
        # Anything short of a completed claim is reversed, including a tree
        # import that failed partway: the importer's record covers every file it
        # published before raising. An incomplete reversal is logged rather than
        # raised — the original failure is the one worth reporting — and its
        # record is kept so the next attempt (or an undo) can retry.
        reversed = claimed || reverse_publication!(importer.publication_record, owner)
        unless reversed
          Rails.logger.error(
            "[LibraryAcquisitionService] Could not fully reverse the failed import for book ##{book.id}; " \
              "some published files remain in the library"
          )
        end
        # A reversed move puts the source back on a fresh inode, so the recorded
        # identity would fail the next attempt's check.
        refresh_source_identity!(owner) if reversed && !claimed && mode == "move"
        release_reservation!(book, owner)
        raise
      end
    end

    # Reverse a completed import so the detection returns to the queue and can be
    # re-imported against a different match (e.g. "new book" approved by mistake).
    #
    # Copy / hardlink imports leave the source in place, so undo just discards the
    # library artifact; a move consumed the source, so undo returns the artifact
    # to where the scanner found it. Either way the book is un-acquired, and a
    # throwaway book created solely for this import (no metadata, no
    # requests/uploads/owned items) is destroyed rather than left behind.
    def undo_import!(detected_import)
      book = detected_import.imported_book
      publication = detected_import.publication_record

      if publication.present?
        # Only a complete reversal earns the state reset below. A file that is no
        # longer the one this import published (renamed, re-tagged, replaced) is
        # left alone; un-acquiring the book anyway would strand it in the library
        # and let a re-import duplicate it.
        #
        # The journal is deliberately not cleared here — it is the only durable
        # description of what this import put on disk, and the transaction below
        # can still fail after the files have moved. That transaction clears it,
        # so a retried undo always has a record to work from and every step is
        # idempotent.
        unless reverse_publication!(publication, detected_import, clear_record: false)
          raise AcquisitionConflictError,
            "Refusing to undo: the file this import published could not be returned or removed — it has been " \
            "renamed, replaced, or moved since. Resolve it under #{publication['base_path']} and try again."
        end
        refresh_source_identity!(detected_import) if publication["mode"].to_s == "move"
      elsif book&.file_path.present?
        # Without an exact record there is no safe way to tell this import's
        # files from anything else under the same templated directory, and
        # guessing is how unrelated files get deleted. Leave both to the admin.
        raise AcquisitionConflictError,
          "Refusing to undo: this import predates publication tracking, so #{book.file_path} " \
          "must be removed manually before it can be re-imported"
      end

      ActiveRecord::Base.transaction do
        detected_import.update!(
          status: "detected",
          imported_book: nil,
          suggested_book: nil,
          error_message: nil,
          publication_record: nil
        )
        release_book_after_undo!(book) if book
      end
    end

    def audio_file?(path)
      AUDIO_EXTENSIONS.include?(normalized_extension(path))
    end

    def readable_file?(path)
      READABLE_EXTENSIONS.include?(normalized_extension(path))
    end

    # Just the online alternates for an already-parsed title/author. Used by
    # deferred enrichment so provider lookups run off the scan hot path, one
    # queued job per detection.
    def online_candidates_for(title:, author:, book_type:)
      online_candidates(title, author, book_type.to_s)
    end

    # Free-text search for the review page's manual "find the correct book" step.
    # Unlike +online_candidates+, results are scored against the admin's query
    # and unfiltered — the admin asked for exactly these, so every hit is offered
    # as a selectable candidate.
    def search_candidates(query:, book_type:, limit: MAX_ONLINE_CANDIDATES)
      query = query.to_s.strip
      return [] if query.blank?

      results = MetadataService.search(
        query, limit: limit, content_kind: metadata_content_kind(book_type)
      )
      normalized_query = query.downcase
      results.map do |result|
        haystack = [ result.title, result.author ].compact.join(" ").downcase
        online_candidate(result, string_similarity(haystack, normalized_query))
      end.sort_by { |candidate| -candidate["score"] }
    rescue *METADATA_ERRORS => e
      Rails.logger.warn "[LibraryAcquisitionService] Manual search failed (#{e.class})"
      []
    end

    private

    # An owner already carrying a publication record reached durable state on an
    # earlier attempt: bytes are on disk and, for a move, the source is gone.
    # Re-importing from that source would read a dead path and fail, stranding
    # the bytes, journal, and reservation with no way to undo. Reconcile first.
    #
    # If that attempt also claimed the book, the import finished and only the
    # bookkeeping was lost — hand back its result instead of publishing a second
    # copy. Otherwise reverse it, returning a moved source to the watched folder,
    # and import again from there.
    def recover_interrupted_publication!(owner, book, source_identity)
      record = journals_publication?(owner) ? owner.publication_record.presence : nil
      book.reload

      if record.blank?
        # An attempt killed between reserve_book! and the journal write left
        # nothing to reverse — but its reservation outlives it, and nothing else
        # clears one held by this owner (the upload and download recovery jobs
        # only reclaim their own). Left in place it fails every retry with a
        # conflict and blocks the book for the other pipelines too, permanently.
        # Releasing it is safe for the same reason as in the branch below:
        # release_reservation! only touches a reservation this owner still holds
        # on an unclaimed book.
        release_reservation!(book, owner)
        return Recovery.new(result: nil, reversed: false, source_identity: nil)
      end

      if publication_claimed_by?(record, book)
        Rails.logger.info(
          "[LibraryAcquisitionService] Resuming interrupted import for book ##{book.id}; the library file is already claimed"
        )
        # The interrupted attempt may have died before announcing the file.
        trigger_library_scan(book)
        return Recovery.new(
          result: ImportResult.new(
            book: book,
            destination_path: book.file_path,
            mode: record["mode"].to_s,
            publication: record
          ),
          reversed: false,
          source_identity: nil
        )
      end

      # The dead attempt's reservation would otherwise block reserve_book!.
      release_reservation!(book, owner)
      unless reverse_publication!(record, owner)
        raise AcquisitionConflictError,
          "An earlier import attempt was interrupted and its files could not be reversed. " \
          "Resolve them under #{record['base_path']} and try again."
      end

      # A reversed move puts the source back on a fresh inode (the restore is a
      # durable copy plus unlink, not a rename), so the identity must be re-read.
      # Copy and hardlink never touched the source, so theirs still stands.
      identity = record["mode"].to_s == "move" ? refresh_source_identity!(owner) : source_identity
      Rails.logger.warn(
        "[LibraryAcquisitionService] Reversed an interrupted import for book ##{book.id} before retrying"
      )
      Recovery.new(result: nil, reversed: true, source_identity: identity)
    end

    # Whether the book's claimed file_path is what this publication produced: the
    # file it published, or the per-book directory it published into.
    def publication_claimed_by?(record, book)
      claimed = book.file_path.presence
      return false if claimed.blank?

      destinations = Array(record["files"]).filter_map { |entry| entry["destination"].presence }
      return false if destinations.empty?

      destinations.include?(claimed) ||
        destinations.all? { |destination| destination.start_with?(File.join(claimed, "")) }
    end

    # Reserve the book under a row lock so a concurrent upload or download cannot
    # claim the same title while the import runs outside the transaction. Raises
    # if the title is already acquired or reserved.
    def reserve_book!(book, owner)
      ActiveRecord::Base.transaction do
        book.lock!
        book.reload
        if book.acquisition_blocked?
          raise AcquisitionConflictError,
            "This title already has an acquired or in-progress library file; the existing file was preserved"
        end

        book.update!(
          acquisition_reservation_token: SecureRandom.hex(32),
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
      end
    end

    # Attach the imported path and clear the reservation in one compare-and-swap
    # so only the worker still holding this owner's reservation can finalize.
    def claim_file_path!(book, destination, owner)
      claimed = Book.where(id: book.id).unclaimed.reserved_by(owner)
        .update_all(
          Book::RESERVATION_CLEARED.merge(file_path: destination, updated_at: Time.current)
        )
      raise AcquisitionConflictError, "This title was acquired by another process during import" unless claimed == 1

      book.reload
    end

    def release_reservation!(book, owner)
      Book.where(id: book.id).unclaimed.reserved_by(owner)
        .update_all(Book::RESERVATION_CLEARED.merge(updated_at: Time.current))
    rescue => e
      Rails.logger.error "[LibraryAcquisitionService] Failed to release reservation for book ##{book.id} (#{e.class})"
    end

    # Persist what an import published so a rollback or undo can reverse exactly
    # those entries. update_columns so an in-flight import neither validates nor
    # broadcasts a status change.
    #
    # A failure here is fatal on purpose: bytes are on disk and a move has
    # consumed the source, so this write is the only durable thing that can
    # reverse them. Committing without it would leave an acquired book whose undo
    # has nothing to work from; raising instead sends the caller into the
    # rollback, which reverses the in-memory record while it is still available.
    def record_publication!(owner, publication)
      return unless journals_publication?(owner)

      owner.update_columns(publication_record: publication, updated_at: Time.current)
    end

    # Whether +owner+ can carry this import's publication journal. Asked rather
    # than assumed (the service accepts any record), and asked in one place so
    # the read and the two writes agree on what counts as journalled.
    def journals_publication?(owner)
      owner.respond_to?(:publication_record=) && owner.persisted?
    end

    # Comics are searched against a different provider corpus than prose.
    def metadata_content_kind(book_type)
      book_type.to_s == "comicbook" ? "graphic" : nil
    end

    def normalized_extension(path)
      File.extname(path.to_s).delete_prefix(".").downcase
    end

    # Reverse exactly the entries this import published: discard the files it
    # created (or, for a move, return them to where the scanner found them), then
    # drop only the directories it brought into existence, and only while they
    # are still empty. A templated "Author/Book" directory is routinely shared
    # with files this import does not own, so it is never deleted recursively.
    #
    # Containment is structural, not a pathname comparison: every removal walks
    # from the output root through pinned O_NOFOLLOW descriptors, gated on the
    # (device, inode) recorded at publication. Neither an ancestor swapped for a
    # symlink nor a root that canonicalizes differently can redirect it.
    #
    # Returns true only when every recorded file was reversed. A caller that
    # resets state on the reversal must not proceed on false — the library still
    # holds an artifact this import put there. The record is kept so undo can be
    # retried; every step is idempotent, so a retry reverses only what is left.
    #
    # +clear_record+ drops the journal once complete. Callers with durable state
    # still to commit pass false and clear it themselves, so a failure in that
    # window leaves a record to retry from.
    def reverse_publication!(publication, owner, clear_record: true)
      publication = publication.presence || {}
      files = Array(publication["files"])
      root = publication["base_path"].presence
      return files.empty? if root.blank?

      move = publication["mode"].to_s == "move"
      source_base = publication["source_base"].presence
      complete = files.reverse_each.map { |entry|
        move ? restore_moved_file!(entry, root, source_base) : discard_published_file!(entry, root)
      }.all?
      Array(publication["directories"]).reverse_each { |entry| discard_created_directory!(entry, root) }

      clear_publication_record!(owner) if complete && clear_record
      complete
    end

    def clear_publication_record!(owner)
      return unless journals_publication?(owner)

      owner.update_columns(publication_record: nil, updated_at: Time.current)
    rescue => e
      Rails.logger.warn("[LibraryAcquisitionService] Failed to clear publication record (#{e.class})")
    end

    # Copy or hardlink: the source is still present, so the library artifact is a
    # redundant second copy — discard it. True when reversed, including when it
    # was already gone.
    def discard_published_file!(entry, root)
      destination = entry["destination"].presence
      return true if destination.blank?

      case published_file_state(entry, root)
      when :absent then return true
      when :match then nil
      else
        Rails.logger.warn(
          "[LibraryAcquisitionService] Left #{destination} in place during undo: " \
            "it is no longer the file this import published"
        )
        return false
      end

      FileCopyService.remove_regular_file_safely(destination, root: root)
      true
    rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError, SystemCallError => e
      Rails.logger.warn(
        "[LibraryAcquisitionService] Left #{entry['destination']} in place during undo (#{e.class})"
      )
      false
    end

    # Move: the source is gone, so return this file to the path the scanner
    # recorded. Restoring per file rebuilds a moved tree exactly as it was found.
    def restore_moved_file!(entry, root, source_base)
      destination = entry["destination"].presence
      source = entry["source"].presence
      return true if destination.blank? || source.blank?

      # The library artifact decides what is left to do. Gone means this entry
      # was already reversed; a mismatch means something else owns the path now.
      # Neither may consult the source, whose path may since have been taken over
      # by unrelated bytes.
      case published_file_state(entry, root)
      when :absent then return true
      when :mismatch
        Rails.logger.warn(
          "[LibraryAcquisitionService] Could not return #{destination} to #{source}: " \
            "it is no longer the file this import published"
        )
        return false
      end

      case moved_source_state(entry)
      when :absent then restore_to_source!(entry, root, source_base)
      when :match
        # A directory move publishes every file before unlinking the source tree,
        # so a partway reversal finds the original still in place — the library
        # copy is redundant rather than the only survivor.
        discard_published_file!(entry, root)
      else
        # Something occupies the source path that this import did not take from
        # it. Removing the library copy would destroy the only surviving bytes;
        # overwriting the occupant would destroy someone else's.
        Rails.logger.warn(
          "[LibraryAcquisitionService] Left #{destination} in the library during undo: " \
            "#{source} is occupied by a different file"
        )
        false
      end
    end

    # Return the artifact to the path the scanner recorded, rebuilding any parent
    # directories the move left empty. Both the mkdir and the publication walk
    # from the watched-folder root through pinned O_NOFOLLOW descriptors, so an
    # ancestor swapped for a symlink cannot redirect the restore outside it.
    # Without a recorded root there is nothing safe to pin against, so refuse.
    def restore_to_source!(entry, root, source_base)
      destination = entry["destination"]
      source = entry["source"]
      if source_base.blank?
        Rails.logger.warn(
          "[LibraryAcquisitionService] Could not return #{destination} to #{source}: " \
            "the import recorded no watched-folder root to restore through"
        )
        return false
      end

      FileCopyService.ensure_directory(File.dirname(source), root: source_base)
      FileCopyService.mv_noreplace(
        destination, source,
        root: source_base, allow_compatibility_fallback: true
      )
      true
    rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError, SystemCallError => e
      Rails.logger.warn(
        "[LibraryAcquisitionService] Could not return #{entry['destination']} to #{entry['source']} (#{e.class})"
      )
      false
    end

    # Whether the source path still holds the file this import moved out of it.
    # :absent means the move consumed it and nothing has taken the path since;
    # :match that the original is still there (a partly-reversed move). An import
    # with no recorded identity cannot prove it either way, and
    # path_identity_state reports that as :mismatch — left alone, not assumed
    # ours.
    def moved_source_state(entry)
      FileCopyService.path_identity_state(
        entry["source"], device: entry["source_device"], inode: entry["source_inode"]
      )
    end

    # Drop a directory this import created, but only while still exactly as empty
    # as it was left. remove_directory_child_if_identity quarantines it and
    # restores it untouched if anything has since been written into it.
    def discard_created_directory!(entry, root)
      path = entry["path"].presence
      device = entry["device"]
      inode = entry["inode"]
      return if path.blank? || device.blank? || inode.blank?

      FileCopyService.remove_directory_child_if_identity(
        File.dirname(path),
        File.basename(path),
        root: root,
        device: device,
        inode: inode,
        expected_entries: {}
      )
    rescue FileCopyService::UnsafePathError, SystemCallError => e
      Rails.logger.warn("[LibraryAcquisitionService] Left directory #{entry['path']} in place during undo (#{e.class})")
    end

    # Whether the library still holds the exact inode this import published,
    # listed through descriptors pinned to the output root rather than resolved
    # from the pathname.
    #
    #   :match     - still there, byte for byte the same
    #   :absent    - already gone, nothing left to reverse
    #   :mismatch  - something else occupies the path; never touch it
    def published_file_state(entry, root)
      device = entry["device"]
      inode = entry["inode"]
      basename = File.basename(entry["destination"])
      children = FileCopyService.directory_children(File.dirname(entry["destination"]), root: root)
      child = children.find { |candidate| candidate.name == basename }
      return :absent unless child
      return :mismatch unless child.type == :file
      return :match if device.blank? || inode.blank?

      [ child.device, child.inode ] == [ device, inode ] ? :match : :mismatch
    rescue Errno::ENOENT
      # The templated directory itself is gone, so the file under it is too.
      :absent
    rescue FileCopyService::UnsafePathError, SystemCallError
      :mismatch
    end

    # An undone move put the source back with a fresh inode (a durable copy plus
    # unlink, not a rename), so the identity recorded at detection no longer
    # describes it. Re-record it, or drop it when unreadable — the importer
    # treats a missing identity as unverifiable rather than refusing outright.
    def refresh_source_identity!(detected_import)
      return nil unless detected_import.respond_to?(:source_device=)

      stat = File.lstat(detected_import.source_path)
      detected_import.update_columns(
        source_device: stat.dev, source_inode: stat.ino, updated_at: Time.current
      )
      [ stat.dev, stat.ino ]
    rescue => e
      # Never raise: this also runs while unwinding a failed import, whose
      # original error is the one worth reporting.
      Rails.logger.warn("[LibraryAcquisitionService] Clearing source identity after undo (#{e.class})")
      begin
        detected_import.update_columns(source_device: nil, source_inode: nil, updated_at: Time.current)
      rescue => inner
        Rails.logger.warn("[LibraryAcquisitionService] Could not clear source identity (#{inner.class})")
      end
      nil
    end

    # Un-acquire the book, destroying it when it was a throwaway created solely
    # for this import (no metadata identity, nothing else referencing it). A
    # matched or metadata-bearing book is kept, merely un-acquired.
    def release_book_after_undo!(book)
      book.reload
      book.update!(Book::RESERVATION_CLEARED.merge(file_path: nil))

      if book.unified_work_id.blank? &&
          book.requests.none? && book.uploads.none? && book.owned_library_items.none?
        book.destroy
      end
    end

    # Resolved by PathTemplateService rather than restated: this root is handed
    # to LibraryFileImporter, which renders the path template beneath it, so the
    # two must agree on where a book type lives.
    def output_base_path(book)
      PathTemplateService.output_root_for(book)
    end

    def trigger_library_scan(book)
      return unless LibraryPlatformClient.configured?

      library_id = SettingsService.library_id_for_book(book)
      return if library_id.blank?

      LibraryPlatformClient.scan_library(library_id)
      Rails.logger.info "[LibraryAcquisitionService] Triggered library scan for book ##{book.id}"
    rescue LibraryPlatformClient::Error => e
      Rails.logger.warn "[LibraryAcquisitionService] Failed to trigger library scan (#{e.class})"
    end

    # The persisted shape of one provider hit. Automatic enrichment and the
    # admin's manual search both offer candidates through this hash; only the
    # score differs, since they rank against different queries.
    def online_candidate(result, score)
      {
        "kind" => "online",
        "work_id" => result.work_id,
        "title" => result.title,
        "author" => result.author,
        "year" => result.year,
        "cover_url" => result.cover_url,
        "source" => result.source,
        "score" => score
      }
    end

    def library_candidate(book, score)
      {
        "kind" => "library",
        "book_id" => book.id,
        "title" => book.title,
        "author" => book.author,
        "score" => score
      }
    end

    # Best-effort online enrichment; failures degrade to an empty alternate list.
    def online_candidates(title, author, book_type)
      return [] if title.blank?

      query = author.present? ? "#{title} #{author}" : title
      results = MetadataService.search(
        query, limit: MAX_ONLINE_CANDIDATES, content_kind: metadata_content_kind(book_type)
      )
      results.filter_map do |result|
        score = online_score(result, title, author)
        next if score < 30

        online_candidate(result, score)
      end.sort_by { |candidate| -candidate["score"] }
    rescue *METADATA_ERRORS => e
      Rails.logger.warn "[LibraryAcquisitionService] Metadata search failed (#{e.class})"
      []
    end

    def online_score(result, query_title, query_author)
      score = 0
      if result.title.present? && query_title.present?
        score += (string_similarity(result.title.downcase, query_title.downcase) * 0.6).round
      end
      if result.author.present? && query_author.present?
        score += (string_similarity(result.author.downcase, query_author.downcase) * 0.4).round
      elsif result.author.present?
        score += 10
      end
      score
    end

    def string_similarity(str1, str2)
      return 100 if str1 == str2
      return 0 if str1.blank? || str2.blank?

      trigrams1 = to_trigrams(str1)
      trigrams2 = to_trigrams(str2)
      return 0 if trigrams1.empty? || trigrams2.empty?

      intersection = (trigrams1 & trigrams2).size
      union = (trigrams1 | trigrams2).size
      ((intersection.to_f / union) * 100).round
    end

    def to_trigrams(str)
      padded = "  #{str}  "
      (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
    end
  end
end
