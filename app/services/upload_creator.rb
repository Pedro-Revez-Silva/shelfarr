class UploadCreator
  MAX_UPLOAD_BYTES = 10.gigabytes
  Result = Struct.new(:upload, :uploads, :notice, :alert, :success, keyword_init: true) do
    def success?
      success.nil? ? alert.blank? : success
    end
  end

  def self.call(user:, uploaded_file:, request: nil)
    new(user:, uploaded_file:, request:).call
  end

  def self.call_many(user:, uploaded_files:, request: nil, skip_unsupported: false)
    submitted_files = Array(uploaded_files).compact_blank
    return Result.new(alert: "Please select a file to upload", success: false) if submitted_files.empty?

    files = submitted_files
    files = files.select { |file| supported_file?(file) } if skip_unsupported
    if skip_unsupported && files.empty?
      return Result.new(alert: "No supported ebook or audiobook files found in the selected folder", success: false)
    end

    if request.present? && files.many?
      return Result.new(alert: "Please upload one file when fulfilling a request", success: false)
    end

    return call(user:, uploaded_file: files.first, request:) if files.one? && !skip_unsupported

    uploads = []
    failures = []

    files.each do |file|
      result = call(user:, uploaded_file: file, request:)
      if result.success?
        uploads << result.upload
      else
        failures << [ file.original_filename, result.alert ]
      end
    end

    if uploads.empty?
      return Result.new(alert: bulk_failure_message(failures), success: false)
    end

    Result.new(
      uploads: uploads,
      notice: "#{uploads.size} #{'file'.pluralize(uploads.size)} uploaded successfully. Processing started.",
      alert: bulk_failure_message(failures),
      success: true
    )
  end

  def self.bulk_failure_message(failures)
    return if failures.empty?

    failed_files = failures.map { |filename, alert| "#{filename}: #{alert}" }.join("; ")
    "#{failures.size} #{'file'.pluralize(failures.size)} failed to upload: #{failed_files}"
  end

  def self.supported_file?(uploaded_file)
    extension = File.extname(uploaded_file.original_filename).delete(".").downcase
    Upload::SUPPORTED_EXTENSIONS.include?(extension)
  end

  def initialize(user:, uploaded_file:, request: nil)
    @user = user
    @uploaded_file = uploaded_file
    @request = request
  end

  def call
    return Result.new(alert: "Please select a file to upload") unless uploaded_file

    extension = File.extname(uploaded_file.original_filename).delete(".").downcase
    unless Upload::SUPPORTED_EXTENSIONS.include?(extension)
      return Result.new(
        alert: "Unsupported file type. Supported: #{Upload::SUPPORTED_EXTENSIONS.join(', ')}"
      )
    end

    if request.present? && inferred_book_type(extension) != request.book.book_type
      return Result.new(alert: "Uploaded file type does not match this #{request.book.book_type} request")
    end

    if request.present? && !request.upload_fulfillable?
      return Result.new(alert: "This request is no longer open for file fulfillment")
    end
    if request.present? && request.upload_cancellation_blocked?
      return Result.new(alert: request.upload_cancellation_blocked_message)
    end
    if request.present? && request.direct_acquisition_recovery_pending?
      return Result.new(alert: request.direct_acquisition_recovery_message)
    end

    begin
      temp_path, actual_size = save_uploaded_file
    rescue UploadImportFileService::IngressTooLargeError => error
      return Result.new(alert: error.message)
    rescue UploadImportFileService::Error
      return Result.new(alert: "Shelfarr could not save the upload safely. Please try again.")
    end

    upload = Upload.new(
      user: user,
      request: request,
      original_filename: uploaded_file.original_filename,
      file_path: temp_path,
      file_size: actual_size,
      content_type: uploaded_file.content_type,
      status: :pending
    )

    if persist_upload(upload)
      if enqueue_processing(upload)
        Result.new(upload: upload, notice: "File uploaded successfully. Processing started.")
      else
        upload.update!(
          status: :failed,
          error_message: "Shelfarr could not queue this upload for processing"
        )
        Result.new(
          upload: upload,
          alert: "The file was saved, but processing could not be queued. Retry it from Uploads."
        )
      end
    else
      UploadImportFileService.discard_ingress!(temp_path)
      Result.new(upload: upload, alert: upload.errors.full_messages.join(", "))
    end
  end

  private

  attr_reader :user, :uploaded_file, :request

  def inferred_book_type(extension)
    return "comicbook" if Upload::COMICBOOK_EXTENSIONS.include?(extension)

    Upload::AUDIOBOOK_EXTENSIONS.include?(extension) ? "audiobook" : "ebook"
  end

  def save_uploaded_file
    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    random = SecureRandom.hex(16)
    extension = File.extname(uploaded_file.original_filename)
    filename = "#{timestamp}_#{random}#{extension}"
    UploadImportFileService.stage_ingress!(
      uploaded_file,
      filename,
      max_bytes: MAX_UPLOAD_BYTES
    )
  end

  def persist_upload(upload)
    return upload.save unless request

    request.with_acquisition_transition_lock do |locked_request|
      unless locked_request.upload_fulfillable?
        raise Request::CancellationBlockedError,
          "This request is no longer open for file fulfillment"
      end
      if locked_request.upload_cancellation_blocked?
        raise Request::CancellationBlockedError,
          locked_request.upload_cancellation_blocked_message
      end
      if locked_request.direct_acquisition_recovery_pending?
        raise Request::CancellationBlockedError,
          locked_request.direct_acquisition_recovery_message
      end

      upload.request = locked_request
      upload.save!
    end
    true
  rescue Request::CancellationBlockedError => error
    upload.errors.add(:base, error.message)
    false
  rescue ActiveRecord::RecordNotFound
    upload.errors.add(:base, "This request is no longer available for file fulfillment")
    false
  rescue ActiveRecord::RecordInvalid
    false
  end

  def enqueue_processing(upload)
    job = UploadProcessingJob.perform_later(upload.id)
    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  rescue StandardError => error
    Rails.logger.error(
      "[UploadCreator] Could not enqueue upload ##{upload.id}: #{error.class}"
    )
    false
  end
end
