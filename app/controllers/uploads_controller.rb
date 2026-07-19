# frozen_string_literal: true

class UploadsController < ApplicationController
  before_action :require_upload_access, only: [ :new, :create ]
  before_action :set_request_context, only: [ :new, :create ]
  before_action :set_upload, only: [ :show ]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @uploads = policy_scope(Upload)
  end

  def show
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

  private

  def require_upload_access
    authorize!(
      :"#{action_name}?",
      Upload,
      fallback_location: root_path,
      alert: "Uploads are not currently enabled."
    )
  end

  def set_upload
    @upload = policy_scope(Upload).find(params[:id])
  end

  def set_request_context
    return if params[:request_id].blank?

    @request = Request.includes(:book).find(params[:request_id])
    unless Current.user.admin? || @request.user == Current.user
      redirect_to uploads_path, alert: "You cannot upload files for this request."
      return
    end

    return if @request.upload_fulfillable?

    message = if @request.completed?
      "This request is already completed."
    else
      "This request is no longer open for file fulfillment. Retry it before uploading a file."
    end
    redirect_to @request, alert: message
  end

  def upload_success_location
    @request || uploads_path
  end

  def upload_failure_location
    @request ? new_upload_path(request_id: @request.id) : new_upload_path
  end

  def upload_files
    params[:files].presence || params[:file]
  end

  def folder_upload?
    params[:upload_mode] == "folder"
  end

  def record_not_found
    head :not_found
  end
end
