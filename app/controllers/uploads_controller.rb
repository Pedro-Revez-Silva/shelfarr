# frozen_string_literal: true

class UploadsController < ApplicationController
  before_action :require_user_uploads_enabled
  before_action :set_upload, only: [ :show ]

  def index
    @uploads = if Current.user.admin?
      Upload.includes(:user, :book).recent
    else
      Upload.for_user(Current.user).includes(:book).recent
    end
  end

  def show
  end

  def new
    @upload = Upload.new
  end

  def create
    uploaded_file = params[:file]

    unless uploaded_file
      redirect_to new_upload_path, alert: "Please select a file to upload"
      return
    end

    extension = File.extname(uploaded_file.original_filename).delete(".").downcase
    unless Upload::SUPPORTED_EXTENSIONS.include?(extension)
      redirect_to new_upload_path,
        alert: "Unsupported file type. Supported: #{Upload::SUPPORTED_EXTENSIONS.join(", ")}"
      return
    end

    temp_path = save_uploaded_file(uploaded_file)

    @upload = Upload.new(
      user: Current.user,
      original_filename: uploaded_file.original_filename,
      file_path: temp_path,
      file_size: uploaded_file.size,
      content_type: uploaded_file.content_type,
      status: :pending
    )

    if @upload.save
      UploadProcessingJob.perform_later(@upload.id)
      redirect_to uploads_path, notice: "File uploaded successfully. Processing started."
    else
      FileUtils.rm_f(temp_path)
      redirect_to new_upload_path, alert: @upload.errors.full_messages.join(", ")
    end
  end

  private

  def require_user_uploads_enabled
    unless SettingsService.user_uploads_allowed? || Current.user&.admin?
      redirect_to root_path, alert: "Uploads are not currently enabled."
    end
  end

  def set_upload
    @upload = if Current.user.admin?
      Upload.find(params[:id])
    else
      Upload.for_user(Current.user).find(params[:id])
    end
  end

  def save_uploaded_file(uploaded_file)
    upload_dir = Rails.root.join("tmp", "uploads")
    FileUtils.mkdir_p(upload_dir)

    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    random = SecureRandom.hex(4)
    extension = File.extname(uploaded_file.original_filename)
    filename = "#{timestamp}_#{random}#{extension}"

    path = upload_dir.join(filename)

    File.open(path, "wb") do |file|
      file.write(uploaded_file.read)
    end

    path.to_s
  end
end
