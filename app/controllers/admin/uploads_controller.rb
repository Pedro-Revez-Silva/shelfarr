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
      # Clean up file if still exists and not completed
      if @upload.file_path.present? && File.exist?(@upload.file_path) && !@upload.completed?
        FileUtils.rm_f(@upload.file_path)
      end

      @upload.destroy
      redirect_to admin_uploads_path, notice: "Upload deleted."
    end

    def retry
      unless @upload.failed?
        redirect_to admin_uploads_path, alert: "Can only retry failed uploads"
        return
      end

      @upload.update!(status: :pending, error_message: nil)
      UploadProcessingJob.perform_later(@upload.id)

      redirect_to admin_uploads_path, notice: "Upload queued for retry."
    end

    private

    def set_upload
      @upload = Upload.find(params[:id])
    end

    def set_request_context
      return if params[:request_id].blank?

      @request = Request.includes(:book).find(params[:request_id])
      redirect_to @request, alert: "This request is already completed." if @request.completed?
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
  end
end
