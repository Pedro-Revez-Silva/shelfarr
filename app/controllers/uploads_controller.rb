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
    uploaded_files = Array(params[:file])
    results = uploaded_files.map do |file|
      UploadCreator.call(user: Current.user, uploaded_file: file, request: @request)
    end

    success_count = results.count(&:success?)
    failure_count = results.count { |r| !r.success? }

    if success_count > 0 && failure_count == 0
      notice = success_count == 1 ? "File uploaded successfully." : "#{success_count} files uploaded successfully."
      redirect_to upload_success_location, notice: "#{notice} Processing started."
    elsif success_count > 0 && failure_count > 0
      flash[:notice] = "#{success_count} files uploaded successfully."
      flash[:alert] = "#{failure_count} files failed to upload: #{results.reject(&:success?).map(&:alert).uniq.join(', ')}"
      redirect_to upload_success_location
    else
      alert = results.first&.alert || "Please select a file to upload"
      redirect_to upload_failure_location, alert: alert
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

    redirect_to @request, alert: "This request is already completed." if @request.completed?
  end

  def upload_success_location
    @request || uploads_path
  end

  def upload_failure_location
    @request ? new_upload_path(request_id: @request.id) : new_upload_path
  end

  def record_not_found
    head :not_found
  end
end
