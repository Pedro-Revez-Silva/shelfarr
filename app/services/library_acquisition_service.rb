# frozen_string_literal: true

# Shared "identify a book and import a source file into the organised library"
# engine used by any front door that adopts a file which was not acquired
# through a Shelfarr request (currently the watched-folder importer).
#
# The request pipeline still uses UploadProcessingJob / PostProcessingJob
# directly; this service reuses the same underlying identification and
# path-template services so both paths agree on structure and matching.
#
# +identify+ is read-only: it inspects a source file and returns a ranked
# suggestion without creating any Book or touching the filesystem beyond
# reading embedded metadata. +import!+ (see below) performs the actual,
# crash-safe publication once an admin has approved a target Book.
class LibraryAcquisitionService
  # Audio container extensions that mark a file (or the folder containing it) as
  # an audiobook. Distinct from Upload::AUDIOBOOK_EXTENSIONS, which also treats
  # zip/rar archives as audiobook uploads — those are not present in a watched
  # completed-download folder as playable media.
  AUDIO_EXTENSIONS = %w[m4a m4b mp3 aax aac flac ogg opus wav].freeze
  # Single-file readable formats (ebooks + comics), reused from the download
  # importer so both front doors recognise the same file types.
  READABLE_EXTENSIONS = PostProcessingJob::EBOOK_FILE_EXTENSIONS
  MAX_ONLINE_CANDIDATES = 5

  class AcquisitionConflictError < StandardError; end

  # Outcome of a successful import into the organised library.
  ImportResult = Data.define(:book, :destination_path, :mode)

  # Read-only identification result. +candidate_books+ is a ranked array of
  # plain hashes safe to persist as JSON on a DetectedImport.
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
    # source_path   - a regular file to read embedded metadata from. For an
    #                 audiobook folder the caller passes a representative audio
    #                 file inside it.
    # book_type     - optional override; inferred from the path when omitted.
    # filename_hint - name used for the filename-parse fallback (defaults to the
    #                 source basename; the caller passes the folder name for an
    #                 audiobook so the parse reflects the release, not one track).
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

      case File.extname(source_path.to_s).delete_prefix(".").downcase
      when *Upload::COMICBOOK_EXTENSIONS then "comicbook"
      when *AUDIO_EXTENSIONS then "audiobook"
      else "ebook"
      end
    end

    # Import an already-decided book's source file into the organised library,
    # marking the book acquired and triggering a library scan.
    #
    # source_path - file or directory to publish.
    # book        - the target Book (must not already be acquired/reserved).
    # owner       - the record that owns the acquisition reservation for the
    #               duration of the import (e.g. a DetectedImport). Required so
    #               the reservation bridges the gap between the pre-import check
    #               and the file_path claim, exactly like the upload path.
    # mode        - copy / move / hardlink; defaults to the configured
    #               completed_download_import_mode.
    def import!(source_path:, book:, owner:, mode: nil, provenance: nil)
      mode = (mode || SettingsService.get(:completed_download_import_mode, default: "copy")).to_s
      base_path = output_base_path(book)

      reserve_book!(book, owner)
      begin
        result = LibraryFileImporter.new(mode: mode).import(
          source: source_path,
          book: book,
          base_path: base_path
        )
        claim_file_path!(book, result.imported_path, owner)
        trigger_library_scan(book)
        Rails.logger.info(
          "[LibraryAcquisitionService] Imported #{provenance || 'source'} for book ##{book.id} (mode=#{mode})"
        )
        ImportResult.new(book: book, destination_path: result.imported_path, mode: mode)
      rescue
        release_reservation!(book, owner)
        raise
      end
    end

    # Reverse a completed import so the detection returns to the review queue and
    # can be re-imported against a different match (e.g. the admin approved "new
    # book" by mistake when a real match existed).
    #
    # Copy / hardlink imports leave the watched-folder source in place, so undo
    # simply discards the library artifact. A move import consumed the source, so
    # undo returns the artifact to where the scanner found it. Either way the book
    # is un-acquired, and a throwaway book created solely for this import (no
    # metadata, no requests/uploads/owned items) is destroyed rather than left
    # behind un-acquired.
    def undo_import!(detected_import)
      book = detected_import.imported_book
      destination = book&.file_path.presence

      reverse_publication!(destination, detected_import, book) if destination

      ActiveRecord::Base.transaction do
        detected_import.update!(
          status: "detected",
          imported_book: nil,
          suggested_book: nil,
          error_message: nil
        )
        release_book_after_undo!(book) if book
      end
    end

    def audio_file?(path)
      AUDIO_EXTENSIONS.include?(File.extname(path.to_s).delete_prefix(".").downcase)
    end

    def readable_file?(path)
      READABLE_EXTENSIONS.include?(File.extname(path.to_s).delete_prefix(".").downcase)
    end

    # Compute just the online alternate list for an already-parsed title/author.
    # Used by deferred enrichment so the (networked) provider lookups run off the
    # scan hot path, one queued job per detection, rather than thousands of
    # sequential searches inside a single scan.
    def online_candidates_for(title:, author:, book_type:)
      online_candidates(title, author, book_type.to_s)
    end

    # Run a free-text metadata search for the manual "search for the correct
    # book" step on the review page. Unlike +online_candidates+, results are
    # scored against the admin's query (not the auto-parsed title) and no
    # low-score filter is applied — the admin asked for exactly these, so every
    # provider hit is offered as a selectable candidate in the usual hash shape.
    def search_candidates(query:, book_type:, limit: MAX_ONLINE_CANDIDATES)
      query = query.to_s.strip
      return [] if query.blank?

      content_kind = book_type.to_s == "comicbook" ? "graphic" : nil
      results = MetadataService.search(query, limit: limit, content_kind: content_kind)
      normalized_query = query.downcase
      results.map do |result|
        haystack = [ result.title, result.author ].compact.join(" ").downcase
        {
          "kind" => "online",
          "work_id" => result.work_id,
          "title" => result.title,
          "author" => result.author,
          "year" => result.year,
          "cover_url" => result.cover_url,
          "source" => result.source,
          "score" => string_similarity(haystack, normalized_query)
        }
      end.sort_by { |candidate| -candidate["score"] }
    rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
      Rails.logger.warn "[LibraryAcquisitionService] Manual search failed (#{e.class})"
      []
    end

    private

    # Reserve the book under a row lock so a concurrent acquisition (upload or
    # download) cannot claim the same title while the file import runs outside
    # the transaction. Raises if the title is already acquired or reserved.
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
      claimed = Book.where(id: book.id)
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .where(
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
        .update_all(
          file_path: destination,
          acquisition_reservation_token: nil,
          acquisition_reservation_owner_type: nil,
          acquisition_reservation_owner_id: nil,
          updated_at: Time.current
        )
      raise AcquisitionConflictError, "This title was acquired by another process during import" unless claimed == 1

      book.reload
    end

    def release_reservation!(book, owner)
      Book.where(id: book.id)
        .where(
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .update_all(
          acquisition_reservation_token: nil,
          acquisition_reservation_owner_type: nil,
          acquisition_reservation_owner_id: nil,
          updated_at: Time.current
        )
    rescue => e
      Rails.logger.error "[LibraryAcquisitionService] Failed to release reservation for book ##{book.id} (#{e.class})"
    end

    # Remove (or, for a move import, relocate) the artifact this import published
    # into the library. Refuses to touch anything that is not strictly inside the
    # book's configured output root, so a corrupt file_path can never delete an
    # arbitrary path.
    def reverse_publication!(destination, detected_import, book)
      return unless File.exist?(destination)

      unless within_output_root?(destination, book)
        raise AcquisitionConflictError,
          "Refusing to undo: #{destination} is not inside the library output path"
      end

      if File.exist?(detected_import.source_path)
        # Copy or hardlink: the watched-folder source is still present, so the
        # library artifact is a redundant second copy — discard it.
        FileUtils.remove_entry(destination)
      else
        # Move: the source is gone; put the artifact back so it can be re-imported.
        restore_moved_source!(destination, detected_import)
      end
    end

    # Return a moved artifact to the source path the scanner recorded. Audiobook
    # imports are directories at both ends; single-file imports land inside a
    # per-book directory, so the file itself is returned and the emptied wrapper
    # directory removed.
    def restore_moved_source!(destination, detected_import)
      source = detected_import.source_path
      FileUtils.mkdir_p(File.dirname(source))

      if detected_import.book_type == "audiobook" || File.file?(destination)
        FileUtils.mv(destination, source)
      else
        inner = Dir.glob(File.join(destination, "**", "*")).find { |path| File.file?(path) }
        FileUtils.mv(inner || destination, source)
        FileUtils.remove_entry(destination) if File.directory?(destination)
      end
    end

    def within_output_root?(destination, book)
      base = File.realpath(output_base_path(book))
      target = File.expand_path(destination)
      target.start_with?("#{base}#{File::SEPARATOR}")
    rescue ArgumentError, SystemCallError
      false
    end

    # Un-acquire the book and destroy it when it was a throwaway created solely
    # for this import (no metadata identity and nothing else references it). A
    # matched or metadata-bearing book is kept, merely un-acquired.
    def release_book_after_undo!(book)
      book.reload
      book.update!(
        file_path: nil,
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil
      )

      if book.unified_work_id.blank? &&
          book.requests.none? && book.uploads.none? && book.owned_library_items.none?
        book.destroy
      end
    end

    def output_base_path(book)
      if book.comicbook?
        SettingsService.get(:comicbook_output_path, default: "/comics")
      elsif book.ebook?
        SettingsService.get(:ebook_output_path, default: "/ebooks")
      else
        SettingsService.get(:audiobook_output_path, default: "/audiobooks")
      end
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

    def library_candidate(book, score)
      {
        "kind" => "library",
        "book_id" => book.id,
        "title" => book.title,
        "author" => book.author,
        "score" => score
      }
    end

    # Best-effort online enrichment. Network/parse failures degrade to an empty
    # alternate list — the human review step is the correctness backstop.
    def online_candidates(title, author, book_type)
      return [] if title.blank?

      query = author.present? ? "#{title} #{author}" : title
      content_kind = book_type.to_s == "comicbook" ? "graphic" : nil
      results = MetadataService.search(query, limit: MAX_ONLINE_CANDIDATES, content_kind: content_kind)
      results.filter_map do |result|
        score = online_score(result, title, author)
        next if score < 30

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
      end.sort_by { |candidate| -candidate["score"] }
    rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
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
