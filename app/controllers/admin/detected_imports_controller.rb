# frozen_string_literal: true

module Admin
  class DetectedImportsController < BaseController
    # Raised when a picked candidate can no longer be resolved to a book, so the
    # import fails loudly instead of silently importing a different target.
    class SelectionError < StandardError; end

    # How many imported items the history shows before the admin expands it. The
    # full history is only queried when expanded, so the collapsed render stays
    # cheap and the dismissed section stays within reach.
    IMPORTED_PREVIEW_COUNT = 10

    before_action :set_detected_import, only: [ :show, :destroy, :import, :dismiss, :restore, :rematch, :search, :undo ]

    def index
      @pending = DetectedImport.pending_review.includes(:suggested_book).recent
      @dismissed = DetectedImport.where(status: "dismissed").recent.limit(20)
      @scan_status = WatchedFolderScanJob.scan_status

      imported = DetectedImport.where(status: "imported").order(updated_at: :desc)
      @imported_total = imported.count
      @imported_expanded = params[:imported] == "all"
      @imported_has_more = @imported_total > IMPORTED_PREVIEW_COUNT
      @imported = (@imported_expanded ? imported : imported.limit(IMPORTED_PREVIEW_COUNT))
        .includes(:imported_book).to_a
    end

    def show
    end

    # Manually trigger a watched-folder scan, in addition to the recurring one.
    #
    # A scan in flight holds the job's concurrency key, declared
    # on_conflict: :discard, so a manual scan enqueued now would be thrown away.
    # Say so rather than claiming a scan started — the running one is about to
    # report what it found anyway.
    def scan
      if !WatchedFolderScanJob.scanning_enabled?
        redirect_to admin_detected_imports_path,
          alert: "Enable watched-folder import and set a path in Settings first."
      elsif WatchedFolderScanJob.scanning_now?
        redirect_to admin_detected_imports_path,
          notice: "A watched-folder scan is already running. Its results will appear here when it finishes."
      else
        WatchedFolderScanJob.perform_later(manual: true)
        redirect_to admin_detected_imports_path, notice: "Watched-folder scan started."
      end
    end

    # Approve an item: apply any edited book selection, then queue the import.
    def import
      unless @detected_import.actionable?
        redirect_to admin_detected_imports_path, alert: "This item can no longer be imported."
        return
      end

      unless reclaim_stuck_import!(@detected_import)
        redirect_to admin_detected_imports_path,
          alert: "This item is being imported right now. Try again once that attempt finishes."
        return
      end

      apply_selection!(@detected_import)
      DetectedImportJob.perform_later(@detected_import.id)
      redirect_to admin_detected_imports_path,
        notice: "Import queued for \"#{@detected_import.display_title}\"."
    rescue SelectionError => e
      redirect_to admin_detected_import_path(@detected_import), alert: e.message
    rescue => e
      Rails.logger.error "[DetectedImportsController] Import approval failed (#{e.class})"
      redirect_to admin_detected_import_path(@detected_import),
        alert: "Could not queue import for \"#{@detected_import.display_title}\"."
    end

    def dismiss
      @detected_import.update!(status: "dismissed") if @detected_import.actionable?
      redirect_to admin_detected_imports_path, notice: "Dismissed \"#{@detected_import.display_title}\"."
    end

    # Bring a dismissed detection back into the review queue.
    def restore
      @detected_import.update!(status: "detected") if @detected_import.status == "dismissed"
      redirect_to admin_detected_imports_path, notice: "Restored \"#{@detected_import.display_title}\" to the review queue."
    end

    # Reverse a completed import so it can be re-imported against a different
    # match. Removes the published library file — returning it to the watched
    # folder if it was moved — and puts the detection back in the queue.
    def undo
      unless @detected_import.imported?
        redirect_to admin_detected_imports_path, alert: "This item hasn't been imported, so there's nothing to undo."
        return
      end

      LibraryAcquisitionService.undo_import!(@detected_import)
      redirect_to admin_detected_import_path(@detected_import),
        notice: "Undid the import for \"#{@detected_import.display_title}\". Pick the correct match and import again."
    rescue => e
      Rails.logger.error "[DetectedImportsController] Undo failed for ##{@detected_import.id} (#{e.class})"
      redirect_to admin_detected_imports_path,
        alert: "Could not undo the import for \"#{@detected_import.display_title}\"."
    end

    # Manual free-text search, for when neither the suggestion nor the alternates
    # are right. Matches merge into the detection's candidate list so they become
    # selectable radios in the existing import form.
    def search
      query = params[:query].to_s.strip
      if query.blank?
        redirect_to admin_detected_import_path(@detected_import), alert: "Enter a title or author to search."
        return
      end

      results = LibraryAcquisitionService.search_candidates(
        query: query,
        book_type: @detected_import.book_type
      )

      if results.empty?
        redirect_to admin_detected_import_path(@detected_import, query: query),
          alert: "No matches found for \"#{query}\"."
        return
      end

      @detected_import.update!(candidate_books: merge_candidates(@detected_import.candidate_books, results))
      redirect_to admin_detected_import_path(@detected_import, query: query),
        notice: "Found #{results.size} #{'match'.pluralize(results.size)} for \"#{query}\". Pick one, then import."
    rescue => e
      Rails.logger.error "[DetectedImportsController] Manual search failed (#{e.class})"
      redirect_to admin_detected_import_path(@detected_import), alert: "Search failed. Please try again."
    end

    # Re-run identification against the source, refreshing the suggestion and
    # alternates (useful after adding a metadata provider or API key).
    #
    # Reads the source exactly as the scanner did: embedded metadata from the
    # release's own audio file, filename parse from the release name. Re-matching
    # on the folder alone would discard the tags and could replace a good
    # suggestion with a filename-only guess.
    def rematch
      identification = LibraryAcquisitionService.identify(
        source_path: WatchedFolderScanService.metadata_path_for(@detected_import.source_path),
        book_type: @detected_import.book_type,
        filename_hint: File.basename(@detected_import.source_path.to_s)
      )
      @detected_import.update!(
        parsed_title: identification.parsed_title,
        parsed_author: identification.parsed_author,
        match_confidence: identification.match_confidence,
        suggested_book: identification.suggested_book,
        candidate_books: identification.candidate_books
      )
      redirect_to admin_detected_import_path(@detected_import), notice: "Re-matched \"#{@detected_import.display_title}\"."
    rescue => e
      Rails.logger.error "[DetectedImportsController] Rematch failed (#{e.class})"
      redirect_to admin_detected_import_path(@detected_import), alert: "Could not re-match this item."
    end

    # The row is the only thing suppressing re-detection of its source: the
    # scanner recognises a file by the (device, inode) or path on a
    # DetectedImport, so removing one whose file is still in the watched folder
    # puts it back at the top of the queue — with a fresh notification — on the
    # next scan. Removal is for pruning entries whose source is gone; while it is
    # still there, the dismissal is what keeps it out.
    def destroy
      if source_present?(@detected_import)
        redirect_to admin_detected_imports_path,
          alert: "\"#{@detected_import.display_title}\" is still in your watched folder, so the next scan would " \
                 "detect it again. It stays dismissed and out of the review queue for as long as this entry exists."
        return
      end

      @detected_import.destroy
      redirect_to admin_detected_imports_path, notice: "Removed detection."
    end

    private

    # Whether the file is still where the scanner found it. Only presence
    # matters, so no identity is passed and an unreadable path counts as present
    # — refusing to remove an entry is recoverable, resurrecting one is not.
    def source_present?(detected_import)
      FileCopyService.path_identity_state(detected_import.source_path.to_s) != :absent
    end

    def set_detected_import
      @detected_import = DetectedImport.find(params[:id])
    end

    # Prepend fresh search hits, dropping any prior online entry for the same
    # work so repeated searches don't stack duplicates. Library candidates (no
    # work_id) are always preserved.
    def merge_candidates(existing, incoming)
      incoming_work_ids = incoming.filter_map { |candidate| candidate["work_id"] }.to_set
      retained = existing.reject do |candidate|
        candidate["work_id"].present? && incoming_work_ids.include?(candidate["work_id"])
      end
      incoming + retained
    end

    # A wedged "importing" row is actionable only because its lease expired, which
    # DetectedImportJob#claim recognises by the row's age. Everything below —
    # applying a selection, the job's own claim — touches updated_at, pushing the
    # row back inside the lease window and making the claim fail silently. Retire
    # the dead lease first: "failed" is claimable outright and keeps the
    # interrupted attempt visible in the queue.
    #
    # False when the row could not be retired because a worker really is importing
    # it, so the caller can say so instead of flashing "Import queued".
    def reclaim_stuck_import!(detected_import)
      return true unless detected_import.stuck_importing?

      reclaimed = DetectedImport.stuck_importing
        .where(id: detected_import.id)
        .update_all(
          status: "failed",
          error_message: "The previous import was interrupted before it finished.",
          updated_at: Time.current
        )
      return false unless reclaimed == 1

      detected_import.reload
      true
    end

    # Resolve the approve form's decision into the detection's target book,
    # defaulting to the existing suggestion when nothing was selected.
    def apply_selection!(detected_import)
      selection = params[:selection].to_s

      if (match = selection.match(/\Abook:(\d+)\z/))
        book = Book.find_by(id: match[1])
        raise SelectionError, "The selected library book no longer exists. Please choose another match." unless book
        detected_import.update!(suggested_book: book)
      elsif (match = selection.match(/\Awork:(.+)\z/))
        book = resolve_work_candidate(detected_import, match[1])
        raise SelectionError, "The selected match could not be resolved. Try Re-match, then choose again." unless book
        detected_import.update!(suggested_book: book)
      elsif selection == "new"
        apply_metadata_edits!(detected_import)
      end
    end

    def apply_metadata_edits!(detected_import)
      attrs = { suggested_book_id: nil }
      # The two guards differ on purpose: a blank title is a slip (nothing left
      # to name the book by) so the parse stands, while a blank author is an
      # instruction — the only way to clear an author the parse invented.
      attrs[:parsed_title] = params[:title].to_s.strip if params[:title].present?
      attrs[:parsed_author] = params[:author].to_s.strip if params.key?(:author)
      if DetectedImport::BOOK_TYPES.include?(params[:book_type])
        attrs[:book_type] = params[:book_type]
      end
      detected_import.update!(attrs)
    end

    # Resolve an online candidate to a Book, reusing an existing record with that
    # work_id or creating one from the metadata captured at detection (no
    # network).
    def resolve_work_candidate(detected_import, work_id)
      book_type = detected_import.book_type.presence || "ebook"
      existing = Book.find_by_work_id(work_id, book_type: book_type)
      return existing if existing

      candidate = detected_import.candidate_books.find { |c| c["work_id"] == work_id }
      return nil unless candidate

      source, = Book.parse_work_id(work_id)
      book = Book.new(
        title: candidate["title"].presence || detected_import.parsed_title,
        author: candidate["author"],
        book_type: book_type,
        cover_url: candidate["cover_url"],
        year: candidate["year"],
        metadata_source: source
      )
      book.assign_work_id(work_id)
      book.save!
      book
    end
  end
end
