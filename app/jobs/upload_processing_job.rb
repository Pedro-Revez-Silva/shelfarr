# frozen_string_literal: true

# Processes uploaded files:
# 1. Extracts metadata from file (ID3 tags, EPUB OPF, etc.)
# 2. Falls back to filename parsing if extraction fails
# 3. Searches metadata sources (Hardcover/Google Books/OpenLibrary) for enrichment
# 4. Creates book with proper metadata
# 5. Renames file and moves to library location
class UploadProcessingJob < ApplicationJob
  MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES = 2.gigabytes
  MAX_AUDIOBOOK_ZIP_FILES = 10_000
  JOB_CONCURRENCY_LEASE = 2.hours
  USER_ERROR_MESSAGE_LIMIT = 2_000

  queue_as :default
  limits_concurrency to: 1,
    key: ->(upload_id) { "upload-processing-#{upload_id}" },
    duration: JOB_CONCURRENCY_LEASE

  def perform(upload_id)
    database_logger = ActiveRecord::Base.logger
    if database_logger&.respond_to?(:silence)
      database_logger.silence(Logger::INFO) { process_upload(upload_id) }
    else
      process_upload(upload_id)
    end
  end

  private

  # Active Record DEBUG bind output contains parsed metadata, artifact paths,
  # and user-facing failure text. Keep DEBUG SQL muted for this job while the
  # identifier-only operational messages below remain visible at INFO+.
  def process_upload(upload_id)
    upload = claim_pending_upload(upload_id)
    return unless upload

    owned_media_import = OwnedMediaImport.find_by(upload_id: upload.id)
    Rails.logger.info(
      "[UploadProcessingJob] Processing upload ##{upload.id} " \
        "source=#{owned_media_import ? 'owned_media' : 'manual'}"
    )
    file_service = nil
    ordinary_file_service = nil
    zip_file_service = nil
    target_request = upload.request
    target_request_original_status = nil
    target_request_claimed = false

    begin
      raise "Request is already completed" if target_request&.completed?

      if owned_media_import
        claim_owned_media_processing!(owned_media_import, upload)
        OwnedMediaImportFileService.ensure_persistent_staging!(owned_media_import, upload)
        upload.reload
        owned_media_import.reload
        if owned_media_import.destination_path.present?
          file_service = OwnedMediaImportFileService.new(
            media_import: owned_media_import,
            upload: upload,
            book: upload.book
          )
        end
      end
      processing_path = if owned_media_import
        file_service&.processing_path ||
          OwnedMediaImportFileService.recovery_source_path(owned_media_import, upload)
      elsif UploadZipImportFileService.archive_upload?(upload)
        UploadZipImportFileService.recovery_source_path(upload)
      elsif UploadImportFileService.recoverable_file?(upload)
        UploadImportFileService.recovery_source_path(upload)
      else
        upload.file_path
      end

      # Step 1: Extract metadata from the actual file
      extracted = MetadataExtractorService.extract(processing_path)

      if extracted.present?
        Rails.logger.info "[UploadProcessingJob] Upload #{upload.id} contained usable embedded metadata"
      end

      # Step 2: Parse filename as fallback
      parsed = FilenameParserService.parse(upload.original_filename)
      Rails.logger.info "[UploadProcessingJob] Parsed fallback metadata for upload #{upload.id}"

      # Use extracted metadata if available, otherwise fall back to parsed filename
      title = extracted.title.presence || parsed.title
      author = extracted.author.presence || parsed.author

      upload.update!(
        parsed_title: title,
        parsed_author: author,
        match_confidence: extracted.present? ? 90 : parsed.confidence
      )

      # Step 3: Determine book type from explicit request or file extension
      book_type = target_request&.book&.book_type || upload.infer_book_type
      upload.update!(book_type: book_type)

      # Step 4: Search metadata sources for enrichment
      metadata = target_request ? nil : fetch_metadata(title, author)

      if metadata
        Rails.logger.info "[UploadProcessingJob] Matched external metadata for upload ##{upload.id}"
      else
        Rails.logger.info "[UploadProcessingJob] No metadata match for upload ##{upload.id}"
      end

      # Wrap critical operations in transaction for atomicity
      book = nil
      destination = nil
      published_destination = nil
      completed_request = nil

      if owned_media_import
        book = preassociate_owned_media_book(
          media_import: owned_media_import,
          upload: upload,
          target_request: target_request,
          metadata: metadata,
          extracted: extracted,
          parsed: parsed,
          book_type: book_type
        )
      end

      file_service ||= if owned_media_import
        OwnedMediaImportFileService.new(
          media_import: owned_media_import,
          upload: upload,
          book: book
        )
      end

      if owned_media_import.nil? && UploadImportFileService.recoverable_file?(upload)
        destination_book = upload.book || target_request&.book || destination_book_for_metadata(
          metadata: metadata,
          extracted: extracted,
          parsed: parsed,
          book_type: book_type
        )
        book = reserve_upload_book!(upload, destination_book)
        apply_reserved_upload_metadata!(book, metadata:, extracted:, parsed:)
        ordinary_file_service = UploadImportFileService.new(
          upload: upload,
          book: book
        )
        ordinary_file_service.reserve!
        published_destination = ordinary_file_service.publish!
      elsif owned_media_import.nil? && UploadZipImportFileService.archive_upload?(upload)
        planned_book = upload.book || target_request&.book || destination_book_for_metadata(
          metadata: metadata,
          extracted: extracted,
          parsed: parsed,
          book_type: book_type
        )
        book = reserve_upload_book!(upload, planned_book)
        apply_reserved_upload_metadata!(book, metadata:, extracted:, parsed:)
        # The expensive, potentially multi-gigabyte extraction and content
        # verification happen outside the short Book-reservation and database
        # completion transactions. The durable destination reservation makes a
        # killed worker retry the exact same publication path.
        zip_file_service = UploadZipImportFileService.new(
          upload: upload,
          book: book,
          max_bytes: MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES,
          max_files: MAX_AUDIOBOOK_ZIP_FILES
        )
        zip_file_service.reserve!
        published_destination = zip_file_service.publish!
      end

      persist_library_records = lambda do
        ActiveRecord::Base.transaction do
          if target_request
            target_request_original_status = target_request.reload.status
            claim_target_request!(target_request)
            target_request_claimed = true
          end

          # Step 5: Find or create book with metadata. Owned-media books are
          # pre-associated before this transaction so a killed worker can
          # recover the exact planned destination on its next attempt.
          book ||= target_request&.book || find_or_create_book_with_metadata(
            metadata: metadata,
            extracted: extracted,
            parsed: parsed,
            book_type: book_type
          )

          if ordinary_file_service || zip_file_service
            upload.lock!
            upload.reload
            book.lock!
            validate_upload_book_reservation!(upload, book)
          else
            book.lock!
            if book.acquisition_blocked?
              raise "This title already has an acquired library file; the existing file was preserved"
            end
          end

          upload.update!(book: book)
          lock_owned_media_completion!(owned_media_import, upload, book) if owned_media_import
          Rails.logger.info(
            "[UploadProcessingJob] Associated upload ##{upload.id} with book ##{book.id}"
          )

          # Step 6: Move and rename file to library location. Libation files
          # use an atomic same-filesystem finalizer; ordinary uploads retain
          # their existing move/copy behavior.
          destination = if file_service
            file_service.finalize!
          elsif ordinary_file_service
            published_destination
          elsif zip_file_service
            published_destination
          else
            move_to_library(upload, book)
          end

          # Step 7: Update book with file path
          if ordinary_file_service || zip_file_service
            claim_book_file_path!(book, destination, upload)
          else
            book.update!(file_path: destination)
          end

          completed_file_path = if ordinary_file_service
            ordinary_file_service.display_destination_path
          elsif zip_file_service
            zip_file_service.display_destination_path
          else
            upload.file_path
          end
          completed_cleanup_path = if ordinary_file_service
            ordinary_file_service.source_path
          elsif zip_file_service
            zip_file_service.source_path
          end
          upload.update!(
            status: :completed,
            processed_at: Time.current,
            file_path: completed_file_path,
            cleanup_source_path: completed_cleanup_path,
            book_reservation_token: nil,
            book_reservation_created_book: false
          )
          complete_owned_media_import!(owned_media_import, upload, book) if owned_media_import

          completed_request = complete_target_request!(target_request, upload) if target_request
        end
      end

      if file_service
        file_service.with_destination_lock do
          begin
            persist_library_records.call
          rescue
            upload.reload
            unless upload.completed?
              restored = file_service.restore_staging!
              if restored == OwnedMediaImportFileService::SOURCE_ONLY
                file_service.clear_reservation!
              end
            end
            raise
          end
        end
      else
        persist_library_records.call
      end

      cleanup_completed_upload_source(ordinary_file_service || zip_file_service)

      # Step 8: Trigger library platform scan if configured (outside transaction)
      trigger_library_scan(book) if book && LibraryPlatformClient.configured?
      NotificationService.request_completed(completed_request) if completed_request

      Rails.logger.info "[UploadProcessingJob] Completed processing upload #{upload.id}"

    rescue => e
      Rails.logger.error(
        "[UploadProcessingJob] Failed upload ##{upload.id} (#{e.class})"
      )
      restore_target_request_status(target_request, target_request_original_status) if target_request_claimed

      upload.reload
      unless upload.completed?
        restore_owned_media_staging!(file_service, owned_media_import)
        restored = restore_ordinary_upload!(ordinary_file_service || zip_file_service, upload) unless owned_media_import
        if owned_media_import.nil? && restored && upload.reload.destination_path.blank?
          release_upload_book_reservation!(upload)
        end
        fail_upload_processing!(upload, owned_media_import, user_error_message(e))
      end
    end
  end

  # Solid Queue's concurrency lease prevents ordinary overlap, but it is not a
  # correctness boundary: an expired lease, a redelivery, or a manual retry
  # can still present two workers with the same upload. Claim with one SQL
  # compare-and-swap so only the worker which changed pending -> processing is
  # allowed to touch metadata or files.
  def claim_pending_upload(upload_id)
    claimed = Upload.where(id: upload_id, status: Upload.statuses[:pending]).update_all(
      status: Upload.statuses[:processing],
      updated_at: Time.current
    )
    return unless claimed == 1

    Upload.find_by(id: upload_id)
  end

  def restore_owned_media_staging!(file_service, media_import)
    return unless file_service && media_import&.reload&.destination_path.present?

    file_service.with_existing_destination_lock do
      restored = file_service.restore_staging!
      if restored == OwnedMediaImportFileService::SOURCE_ONLY
        file_service.clear_reservation!
      end
    end
  rescue => e
    # Keep the persisted reservation when restoration is not possible. A
    # manual retry or stale-import recovery can then reconcile the exact final
    # file instead of allocating a new path and orphaning it.
    Rails.logger.error(
      "[UploadProcessingJob] Could not restore finalized Audible upload ##{media_import.id} " \
        "(#{e.class})"
    )
  end

  def restore_ordinary_upload!(file_service, upload)
    restored = if file_service
      file_service.restore_and_clear!
    else
      UploadImportFileService.restore_and_clear!(upload)
    end
    return true if restored || upload.destination_path.blank?

    Rails.logger.error(
      "[UploadProcessingJob] Reserved destination for upload #{upload.id} requires manual reconciliation"
    )
    false
  end

  def cleanup_completed_upload_source(file_service)
    file_service&.cleanup_source_after_completion!
  rescue => error
    # The library publication and database completion are already durable.
    # CleanupTempFilesJob can remove the leftover upload source later.
    Rails.logger.warn(
      "[UploadProcessingJob] Could not remove completed source: #{error.class}"
    )
  end

  def claim_book_file_path!(book, destination, upload)
    token = upload.book_reservation_token.to_s
    claimed = Book.where(id: book.id)
      .where("file_path IS NULL OR TRIM(file_path) = ''")
      .where(
        acquisition_reservation_token: token,
        acquisition_reservation_owner_type: "Upload",
        acquisition_reservation_owner_id: upload.id
      )
      .update_all(
        file_path: destination,
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil,
        updated_at: Time.current
      )
    return book.reload if claimed == 1

    raise "This title already has an acquired library file; the existing file was preserved"
  end

  def destination_book_for_metadata(metadata:, extracted:, parsed:, book_type:)
    work_id = metadata&.work_id
    if work_id.present?
      existing = Book.find_by_work_id(work_id, book_type: book_type)
      return existing if existing
    end

    title = metadata&.title || extracted&.title || parsed.title
    author = metadata&.author || extracted&.author || parsed.author
    result = BookMatcherService.match(title: title, author: author, book_type: book_type)
    return result.book if result.exact? || result.fuzzy?

    content_kind = metadata&.content_kind if metadata.respond_to?(:content_kind)
    default_content_kind = book_type.to_s == "comicbook" ? "graphic" : "book"
    book = Book.new({
      title: title,
      author: author,
      book_type: book_type,
      cover_url: metadata&.cover_url,
      year: metadata&.year || extracted&.year,
      description: metadata&.description || extracted&.description,
      series: (metadata&.series_name if metadata.respond_to?(:series_name)),
      series_position: (metadata&.series_position if metadata.respond_to?(:series_position)),
      content_kind: ContentKinds.normalize(content_kind, default: default_content_kind),
      narrator: (extracted&.narrator if extracted.respond_to?(:narrator))
    }.compact)
    if work_id.present?
      source, = Book.parse_work_id(work_id)
      book.assign_work_id(work_id)
      book.metadata_source = source
    end
    book
  end

  def apply_reserved_upload_metadata!(book, metadata:, extracted:, parsed:)
    work_id = metadata&.work_id
    return if work_id.blank?

    apply_metadata_backfill_if_needed(
      book,
      work_id: work_id,
      fallback_attrs: {
        title: metadata&.title || extracted&.title || parsed.title,
        author: metadata&.author || extracted&.author || parsed.author,
        cover_url: metadata&.cover_url,
        year: metadata&.year || extracted&.year,
        description: metadata&.description || extracted&.description,
        series: (metadata&.series_name if metadata.respond_to?(:series_name)),
        series_position: (metadata&.series_position if metadata.respond_to?(:series_position))
      }.compact
    )
  end

  def reserve_upload_book!(upload, planned_book)
    token = upload.book_reservation_token.presence || SecureRandom.hex(32)
    reserved_book = nil

    ActiveRecord::Base.transaction do
      current_upload = Upload.lock.find(upload.id)
      unless current_upload.processing?
        raise "The upload is no longer available for Book reservation"
      end

      created_book = false
      reserved_book = if current_upload.book_id.present?
        Book.lock.find(current_upload.book_id)
      elsif planned_book.persisted?
        Book.lock.find(planned_book.id)
      else
        planned_book.save!
        created_book = true
        planned_book
      end

      if current_upload.book_reservation_token.present?
        validate_upload_book_reservation!(current_upload, reserved_book)
        next
      end

      claimed = Book.where(id: reserved_book.id)
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .where(acquisition_reservation_token: nil)
        .update_all(
          acquisition_reservation_token: token,
          acquisition_reservation_owner_type: "Upload",
          acquisition_reservation_owner_id: current_upload.id,
          updated_at: Time.current
        )
      unless claimed == 1
        raise "Another acquisition already claimed this title; the existing file was preserved"
      end

      current_upload.update!(
        book: reserved_book,
        book_reservation_token: token,
        book_reservation_created_book: created_book
      )
    end

    upload.reload
    reserved_book.reload
  end

  def validate_upload_book_reservation!(upload, book)
    token = upload.book_reservation_token.to_s
    valid = token.present? && upload.book_id == book.id &&
      book.acquisition_reservation_token == token &&
      book.acquisition_reservation_owner_type == "Upload" &&
      book.acquisition_reservation_owner_id == upload.id &&
      !book.acquired?
    return true if valid

    raise "The upload no longer owns this title's acquisition reservation"
  end

  def release_upload_book_reservation!(upload)
    released = false
    ActiveRecord::Base.transaction do
      current_upload = Upload.lock.find(upload.id)
      token = current_upload.book_reservation_token.to_s
      next if token.blank?

      current_book = Book.lock.find_by(id: current_upload.book_id)
      next unless current_book
      validate_upload_book_reservation!(current_upload, current_book)

      current_book.update!(
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil
      )
      created_book = current_upload.book_reservation_created_book?
      current_upload.update!(
        book: nil,
        book_reservation_token: nil,
        book_reservation_created_book: false
      )
      if created_book && !current_book.acquired? &&
          current_book.requests.empty? && current_book.owned_library_items.empty? &&
          current_book.uploads.empty? && !current_book.owned_media_recovery_pending?
        current_book.destroy!
      end
      released = true
    end
    upload.reload
    released
  rescue => error
    Rails.logger.error(
      "[UploadProcessingJob] Could not release Book reservation for upload ##{upload.id}: #{error.class}"
    )
    false
  end

  def preassociate_owned_media_book(
    media_import:, upload:, target_request:, metadata:, extracted:, parsed:, book_type:
  )
    item = media_import.owned_library_item
    local_resolution = OwnedLibraryBookMatcher.new.resolve(item)
    if item.book&.reload&.acquired? || local_resolution.matched?
      raise "This title became available in the Shelfarr library while Libation was backing it up; " \
        "the existing file was preserved"
    end
    if local_resolution.conflict? && !media_import.separate_edition?
      raise "A possible local-library match appeared while Libation was backing up this title; " \
        "the existing file was preserved"
    end

    upload.with_lock do
      upload.reload
      if upload.book
        next upload.book
      end

      created = target_request&.book.blank?
      book = target_request&.book || find_or_create_book_with_metadata(
        metadata: metadata,
        extracted: extracted,
        parsed: parsed,
        book_type: book_type,
        owned_item: item,
        force_new: true
      )
      upload.update!(book: book)
      media_import.update!(created_book: book) if created
      book
    end
  end

  def fail_upload_processing!(upload, media_import, message)
    book_id = media_import&.reload&.created_book_id
    Book.transaction do
      book = Book.lock.find_by(id: book_id) if book_id

      # Completion locks the Book before updating its Upload. Keep the same
      # order here so cleanup cannot deadlock an overlapping redelivery.
      upload.lock!
      upload.reload
      media_import&.lock!
      media_import&.reload
      next if upload.completed?

      upload.update!(status: :failed, error_message: message)
      if media_import&.upload_id == upload.id && media_import.processing?
        media_import.update!(
          status: "failed",
          error_message: message.to_s.truncate(2_000),
          completed_at: Time.current
        )
      end
      next unless book && media_import&.created_book_id == book.id

      adopted = book.acquired? || book.requests.exists? || book.owned_library_items.exists?
      if adopted
        media_import.update!(created_book: nil)
        next
      end
      next if book.uploads.where.not(id: upload.id).exists?

      upload.update!(book: nil) if upload.book_id == book.id
      media_import.update!(created_book: nil)
      book.destroy!
    end
  end

  def claim_owned_media_processing!(media_import, upload)
    media_import.with_lock do
      media_import.reload
      unless media_import.upload_id == upload.id && media_import.status.in?(%w[processing failed])
        raise "This Audible import no longer owns the upload being processed"
      end

      if media_import.failed?
        media_import.update!(
          status: "processing",
          completed_at: nil,
          error_message: nil,
          started_at: Time.current,
          upload_recovery_attempts: 0,
          poll_token: OwnedMediaImport.generate_poll_token
        )
      end
    end
  end

  def lock_owned_media_completion!(media_import, upload, book)
    media_import.lock!
    unless media_import.upload_id == upload.id && media_import.processing?
      raise "This Audible import no longer owns the upload being processed"
    end

    item = media_import.owned_library_item
    item.lock!
    item.reload
    other_completed = item.owned_media_imports
      .where(status: "completed")
      .where.not(id: media_import.id)
      .where("created_at > ? OR (created_at = ? AND id > ?)",
        media_import.created_at, media_import.created_at, media_import.id)
      .exists?
    if item.book&.acquired? || other_completed
      raise "A newer Audible backup already completed for this title"
    end

    local_resolution = OwnedLibraryBookMatcher.new.resolve(item)
    if local_resolution.matched? && local_resolution.book.id != book.id
      raise "This title became available in the Shelfarr library while Libation was backing it up; " \
        "the existing file was preserved"
    end
    if local_resolution.conflict? && !media_import.separate_edition?
      raise "A possible local-library match appeared while Libation was backing up this title; " \
        "the existing file was preserved"
    end

    other_active = item.owned_media_imports
      .active
      .where.not(id: media_import.id)
      .exists?
    if other_active
      raise "A newer Audible backup is already active for this title"
    end
  end

  def complete_owned_media_import!(media_import, upload, book)
    now = Time.current
    media_import.update!(
      status: "completed",
      completed_at: now,
      error_message: nil
    )
    media_import.owned_library_item.update!(
      book: book,
      downloaded: true,
      backed_up_at: now,
      file_path: book.file_path
    )
  end

  # Search metadata sources and return the best matching result
  def fetch_metadata(title, author)
    return nil if title.blank?

    # Build search query - include author if available for better results
    query = author.present? ? "#{title} #{author}" : title

    results = MetadataService.search(query, limit: 5)
    return nil if results.empty?

    # Score results and pick the best match
    best_match = results.max_by { |r| score_result(r, title, author) }

    # Only return if score is reasonable
    score = score_result(best_match, title, author)
    score >= 30 ? best_match : nil
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
    Rails.logger.warn "[UploadProcessingJob] Metadata search failed (#{e.class})"
    nil
  end

  # Score how well a search result matches the parsed title/author
  def score_result(result, query_title, query_author)
    score = 0

    # Title similarity (max 60 points)
    if result.title.present? && query_title.present?
      title_sim = string_similarity(result.title.downcase, query_title.downcase)
      score += (title_sim * 0.6).round
    end

    # Author similarity (max 40 points)
    if result.author.present? && query_author.present?
      author_sim = string_similarity(result.author.downcase, query_author.downcase)
      score += (author_sim * 0.4).round
    elsif result.author.present?
      # Bonus for having an author even if we didn't parse one
      score += 10
    end

    score
  end

  def string_similarity(str1, str2)
    return 100 if str1 == str2
    return 0 if str1.blank? || str2.blank?

    # Simple trigram similarity
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

  def find_or_create_book_with_metadata(
    metadata:,
    extracted:,
    parsed:,
    book_type:,
    owned_item: nil,
    force_new: false
  )
    # Priority: online metadata > extracted file metadata > authoritative
    # owned-catalog metadata > parsed filename. The owned item is supplied only
    # for a Libation import and its cover has already passed the CDN allowlist.
    title = metadata&.title.presence || extracted&.title.presence ||
      owned_item&.display_title.presence || parsed.title
    author = metadata&.author.presence || extracted&.author.presence ||
      owned_item&.author.presence || parsed.author
    work_id = metadata&.work_id
    cover_url = metadata&.cover_url.presence || owned_item&.cover_image_url
    year = metadata&.year || extracted&.year
    description = metadata&.description || extracted&.description
    series = metadata&.series_name if metadata.respond_to?(:series_name)
    series_position = metadata&.series_position if metadata.respond_to?(:series_position)
    content_kind = metadata&.content_kind if metadata.respond_to?(:content_kind)
    default_content_kind = book_type.to_s == "comicbook" ? "graphic" : "book"
    content_kind = ContentKinds.normalize(content_kind, default: default_content_kind)
    narrator = extracted&.narrator.presence if extracted.respond_to?(:narrator)
    narrator ||= owned_item&.narrator

    fallback_attrs = {
      title: title,
      author: author,
      cover_url: cover_url,
      year: year,
      description: description,
      series: series,
      series_position: series_position,
      content_kind: content_kind
    }.compact

    # Check for existing book with same work_id and type
    if work_id.present? && !force_new
      existing = Book.find_by_work_id(work_id, book_type: book_type)
      if existing
        apply_metadata_backfill_if_needed(existing, work_id: work_id, fallback_attrs: fallback_attrs)
        return existing
      end
    end

    # Try to match against existing books
    unless force_new
      result = BookMatcherService.match(title: title, author: author, book_type: book_type)
      if result.exact? || result.fuzzy?
        apply_metadata_backfill_if_needed(result.book, work_id: work_id, fallback_attrs: fallback_attrs)
        return result.book
      end
    end

    # Create new book with metadata
    if work_id.present? && !force_new
      source, _source_id = Book.parse_work_id(work_id)
      book = Book.find_or_initialize_by_work_id(work_id, book_type: book_type)
      book.assign_attributes({
        title: title,
        author: author,
        cover_url: cover_url,
        year: year,
        description: description,
        series: series,
        series_position: series_position,
        content_kind: content_kind,
        narrator: narrator,
        metadata_source: source
      }.compact)
      book.save!
      BookMetadataBackfillService.apply!(book, work_id: work_id, fallback_attrs: fallback_attrs)
      book
    else
      Book.create!({
        title: title,
        author: author,
        book_type: book_type,
        cover_url: cover_url,
        year: year,
        description: description,
        series: series,
        series_position: series_position,
        content_kind: content_kind,
        narrator: narrator
      }.compact)
    end
  end

  def apply_metadata_backfill_if_needed(book, work_id:, fallback_attrs:)
    return if work_id.blank?
    return unless needs_metadata_backfill?(book)

    BookMetadataBackfillService.apply!(
      book,
      work_id: work_id,
      fallback_attrs: fallback_attrs
    )
  end

  def needs_metadata_backfill?(book)
    book.series.blank? ||
      book.series_position.blank? ||
      book.cover_url.blank? ||
      book.year.blank? ||
      book.description.blank?
  end

  def complete_target_request!(request, upload)
    return if request.completed?

    request.downloads.where(status: [ :queued, :downloading, :paused ]).find_each do |download|
      request.cancel_download(download)
    end
    request.complete!
    RequestEvent.record!(
      request: request,
      event_type: "upload_fulfilled",
      source: "upload",
      message: "Request fulfilled by manual upload",
      details: { upload_id: upload.id }
    )
    request
  end

  def claim_target_request!(request)
    claimable_statuses = Request.statuses.values_at(
      "pending", "searching", "awaiting_purchase", "not_found", "downloading", "failed"
    )
    claimed = Request.where(id: request.id, status: claimable_statuses).update_all(
      status: Request.statuses[:processing],
      updated_at: Time.current
    )
    request.reload

    return if claimed == 1

    raise "Request is already completed" if request.completed?

    raise "Request is already being completed"
  end

  def restore_target_request_status(request, original_status)
    return if request.blank? || original_status.blank?

    request.reload
    return if request.completed? || !request.processing?

    request.update!(status: original_status)
  rescue => e
    Rails.logger.warn(
      "[UploadProcessingJob] Failed to restore request ##{request.id} status after upload failure " \
        "(#{e.class})"
    )
  end

  def move_to_library(upload, book)
    source_path = upload.file_path

    unless File.exist?(source_path)
      raise "Source file not found: #{source_path}"
    end

    destination_dir = build_destination_path(book)
    if book.audiobook? && File.extname(upload.original_filename).casecmp?(".zip")
      raise "Audiobook ZIP upload was not initialized with its crash-safe importer"
    end

    FileUtils.mkdir_p(destination_dir)

    # Rename file to standardized format: "Author - Title.ext"
    extension = File.extname(upload.original_filename)
    new_filename = build_filename(book, extension)
    original_destination_file = File.join(destination_dir, new_filename)
    destination_file = original_destination_file

    # Publish without replacing a file another library writer created between
    # candidate selection and the move. Retry with a numbered filename when a
    # concurrent writer wins the exclusive destination.
    loop do
      destination_file = handle_duplicate_filename(destination_file) if path_occupied?(destination_file)
      Rails.logger.info "[UploadProcessingJob] Publishing upload ##{upload.id}"
      begin
        FileCopyService.mv_noreplace(source_path, destination_file)
        break
      rescue Errno::EEXIST
        destination_file = handle_duplicate_filename(original_destination_file)
      end
    end

    # Flat output shares destination_dir across books; track the file itself
    PathTemplateService.flat_output?(book) ? destination_file : destination_dir
  end

  def extract_zip_upload_to_directory(
    zip_path,
    destination_dir,
    max_bytes: MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES,
    max_files: MAX_AUDIOBOOK_ZIP_FILES
  )
    UploadZipImportFileService.extract_archive_to_new_directory!(
      zip_path,
      destination_dir,
      max_bytes: max_bytes,
      max_files: max_files
    )
  rescue UploadZipImportFileService::Error => error
    raise error.message
  end

  def build_filename(book, extension)
    PathTemplateService.build_filename(book, extension)
  end

  def handle_duplicate_filename(path)
    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)

    counter = 1
    new_path = path
    while path_occupied?(new_path)
      counter += 1
      new_path = File.join(dir, "#{base} (#{counter})#{ext}")
    end
    new_path
  end

  def path_occupied?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def build_destination_path(book)
    PathTemplateService.build_destination(book)
  end

  def trigger_library_scan(book)
    library_id = SettingsService.library_id_for_book(book)

    return unless library_id.present?

    LibraryPlatformClient.scan_library(library_id)
    Rails.logger.info "[UploadProcessingJob] Triggered library scan for book ##{book.id}"
  rescue LibraryPlatformClient::Error => e
    Rails.logger.warn "[UploadProcessingJob] Failed to trigger library scan (#{e.class})"
  end

  def user_error_message(error)
    error.message.to_s.scrub.truncate(USER_ERROR_MESSAGE_LIMIT)
  end
end
