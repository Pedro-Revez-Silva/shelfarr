# frozen_string_literal: true

class UploadsController < ApplicationController
  before_action :require_upload_access, only: [ :new, :create ]
  before_action :set_upload, only: [ :show ]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @uploads = policy_scope(Upload)
  end

  def show
  end

  def new
    @upload = Upload.new
  end

  def create
    result = UploadCreator.call(user: Current.user, uploaded_file: params[:file])

    if result.success?
      redirect_to uploads_path, notice: result.notice
    else
      redirect_to new_upload_path, alert: result.alert
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

  def record_not_found
    head :not_found
  end
end
