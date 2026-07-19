# frozen_string_literal: true

module Admin
  class UploadsController < BaseController
    before_action :set_request_context, only: [ :new, :create ]
    before_action :set_upload, only: [ :show, :destroy, :retry ]

    def index
      @uploads = Upload.includes(:user, :book).recent
    end

    def new
      @upload = Upload.new(request: @request)
    end

    def create
      result = UploadCreator.call_many(
        user: Current.user,
        uploaded_files: upload_files,
        request: @request,
        skip_unsupported: folder_upload?
      )

      if result.success?
        flash[:notice] = result.notice if result.notice.present?
        flash[:alert] = result.alert if result.alert.present?
        redirect_to upload_success_location
      else
        redirect_to upload_failure_location, alert: result.alert
      end
    end

    def show
    end

    def destroy
      protected_owned_import = false
      Upload.transaction do
        @upload.lock!
        @upload.reload
        media_import = OwnedMediaImport.lock.find_by(upload_id: @upload.id)

        if @upload.destruction_blocked?
          protected_owned_import = true
        else
          # Upload's before_destroy callback removes an unprocessed source.
          @upload.destroy!
        end
      end

      if protected_owned_import
        redirect_to admin_uploads_path,
          alert: "This upload has a reserved library file and cannot be deleted safely. " \
            "Retry the upload so Shelfarr can reconcile it first."
        return
      end

      redirect_to admin_uploads_path, notice: "Upload deleted."
    rescue ActiveRecord::RecordNotDestroyed
      redirect_to admin_uploads_path,
        alert: "This upload has a reserved library file and cannot be deleted safely. " \
          "Retry the upload so Shelfarr can reconcile it first."
    end

    def retry
      unless @upload.failed?
        redirect_to admin_uploads_path, alert: "Can only retry failed uploads"
        return
      end

      media_import = OwnedMediaImport.find_by(upload_id: @upload.id)
      Upload.transaction do
        @upload.lock!
        @upload.reload
        unless @upload.failed?
          @upload.errors.add(:base, "Can only retry failed uploads")
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

      unless enqueue_retry(media_import)
        if media_import
          redirect_to admin_uploads_path,
            alert: "Immediate retry could not be queued. Shelfarr will recover this Audible import automatically."
        else
          @upload.update!(status: :failed, error_message: "Shelfarr could not queue the upload retry")
          redirect_to admin_uploads_path, alert: "Upload retry could not be queued. Try again."
        end
        return
      end

      redirect_to admin_uploads_path, notice: "Upload queued for retry."
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
      redirect_to admin_uploads_path, alert: message.presence || "This upload cannot be retried right now."
    end

    private

    def set_upload
      @upload = Upload.find(params[:id])
    end

    def set_request_context
      return if params[:request_id].blank?

      @request = Request.includes(:book).find(params[:request_id])
      return if @request.upload_fulfillable?

      message = if @request.completed?
        "This request is already completed."
      else
        "This request is no longer open for file fulfillment. Retry it before uploading a file."
      end
      redirect_to @request, alert: message
    end

    def upload_success_location
      @request || admin_uploads_path
    end

    def upload_failure_location
      @request ? new_admin_upload_path(request_id: @request.id) : new_admin_upload_path
    end

    def upload_files
      params[:files].presence || params[:file]
    end

    def folder_upload?
      params[:upload_mode] == "folder"
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
      false
    end
  end
end
