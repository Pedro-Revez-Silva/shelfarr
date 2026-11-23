# frozen_string_literal: true

class UploadAdministration
  Outcome = Struct.new(:kind, :message, keyword_init: true) do
    def done?
      kind == :done
    end
  end

  MatchChoices = Struct.new(:query, :page, :books, :manual_book, keyword_init: true)

  MATCHES_PER_PAGE = 20
  RESERVED_FILE_MESSAGE = "This upload has a reserved library file and cannot be deleted safely. " \
    "Retry the upload so Shelfarr can reconcile it first."
  ONLY_FAILED = "Can only retry failed uploads"

  def initialize(upload, user:)
    @upload = upload
    @user = user
  end

  def destroy
    protected_owned_import = false
    Upload.transaction do
      @upload.lock!
      @upload.reload
      OwnedMediaImport.lock.find_by(upload_id: @upload.id)

      if @upload.destruction_blocked?
        protected_owned_import = true
      else
        @upload.destroy!
      end
    end
    return Outcome.new(kind: :refused, message: RESERVED_FILE_MESSAGE) if protected_owned_import

    Outcome.new(kind: :done, message: "Upload deleted.")
  rescue ActiveRecord::RecordNotDestroyed
    Outcome.new(kind: :refused, message: RESERVED_FILE_MESSAGE)
  end

  def retry
    return Outcome.new(kind: :refused, message: ONLY_FAILED) unless @upload.failed?

    media_import = OwnedMediaImport.find_by(upload_id: @upload.id)
    restart(media_import)

    unless RemoteResult.succeeded?(enqueue_retry(media_import))
      return Outcome.new(kind: :queue_failed, message: "Immediate retry could not be queued. Shelfarr will recover this Audible import automatically.") if media_import

      @upload.update!(status: :failed, error_message: "Shelfarr could not queue the upload retry")
      return Outcome.new(kind: :queue_failed, message: "Upload retry could not be queued. Try again.")
    end

    Outcome.new(kind: :done, message: "Upload queued for retry.")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    Outcome.new(kind: :refused, message: message.presence || "This upload cannot be retried right now.")
  end

  def match_and_retry(attributes)
    @upload.match_and_retry!(**attributes)
    ActivityTracker.track("upload.manually_matched", user: @user, trackable: @upload,
      details: { book_id: @upload.book_id, choice: attributes[:book_id] ? "existing" : "created" }
    )

    unless RemoteResult.succeeded?(enqueue_retry(nil))
      Upload.where(id: @upload.id, status: :pending).update_all(
        status: Upload.statuses[:failed],
        error_message: "Shelfarr could not queue the upload retry. Your manual match was saved.",
        updated_at: Time.current
      )
      return Outcome.new(kind: :queue_failed, message: "Upload retry could not be queued. Your manual match was saved; try Retry again.")
    end

    Outcome.new(kind: :done, message: "Manual match saved. Upload queued for retry.")
  rescue ActiveRecord::RecordInvalid => error
    Outcome.new(kind: :invalid, message: error.record.errors.full_messages.to_sentence)
  rescue ActiveRecord::RecordNotFound
    Outcome.new(kind: :book_missing, message: "That book is no longer available. Choose another book.")
  end

  def match_choices(query:, page:, manual_book:)
    return unless @upload.manual_match_available?

    match_query = (query.nil? ? @upload.parsed_title : query).to_s.strip.first(200)
    match_page = Integer(page, exception: false).to_i.clamp(1, 100_000)
    parsed = FilenameParserService.parse(@upload.original_filename)
    fields = manual_book || {}
    prefill = Book.new(
      title: fields[:title] || @upload.book&.title || @upload.parsed_title.presence || parsed.title,
      author: fields[:author] || @upload.book&.author || @upload.parsed_author.presence || parsed.author
    )
    books = Book.where(book_type: @upload.infer_book_type)
      .where("file_path IS NULL OR TRIM(file_path) = ''")
      .where(acquisition_reservation_token: nil)
    if match_query.present?
      pattern = "%#{Book.sanitize_sql_like(match_query)}%"
      books = books.where("title LIKE :query ESCAPE '\\' OR author LIKE :query ESCAPE '\\'", query: pattern)
    end
    books = books.order(:title, :id).offset((match_page - 1) * MATCHES_PER_PAGE).limit(MATCHES_PER_PAGE + 1).to_a
    MatchChoices.new(query: match_query, page: match_page, books: books, manual_book: prefill)
  end

  private

  def restart(media_import)
    Upload.transaction do
      @upload.lock!
      @upload.reload
      unless @upload.failed?
        @upload.errors.add(:base, ONLY_FAILED)
        raise ActiveRecord::RecordInvalid.new(@upload)
      end

      if media_import
        media_import.lock!
        media_import.reload
        unless media_import.failed? && media_import.upload_id == @upload.id
          media_import.errors.add(:base, "Audible import is not retryable")
          raise ActiveRecord::RecordInvalid.new(media_import)
        end
        media_import.update!(
          status: "processing",
          completed_at: nil,
          error_message: nil,
          started_at: Time.current,
          upload_recovery_attempts: 0,
          poll_token: OwnedMediaImport.generate_poll_token
        )
      end
      @upload.update!(status: :pending, error_message: nil)
    end
  end

  def enqueue_retry(media_import)
    job = if media_import
      OwnedMediaBackupJob.perform_later(media_import.id, media_import.poll_token)
    else
      UploadProcessingJob.perform_later(@upload.id)
    end

    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  rescue ActiveJob::EnqueueError => error
    Rails.logger.error(
      "[UploadsController] Could not enqueue retry for upload ##{@upload.id}: #{error.class}"
    )
    RemoteResult::Failed.new(error)
  end
end
