# frozen_string_literal: true

module Admin
  class UploadsController < BaseController
    before_action :set_upload, only: [:show, :destroy, :retry]

    def index
      @uploads = Upload.includes(:user, :book).recent
    end

    def new
      @upload = Upload.new
    end

    def create
      result = UploadCreator.call(user: Current.user, uploaded_file: params[:file])

      if result.success?
        redirect_to admin_uploads_path, notice: result.notice
      else
        redirect_to new_admin_upload_path, alert: result.alert
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
  end
end
