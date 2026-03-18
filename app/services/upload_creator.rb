class UploadCreator
  Result = Struct.new(:upload, :notice, :alert, keyword_init: true) do
    def success?
      alert.blank?
    end
  end

  def self.call(user:, uploaded_file:)
    new(user:, uploaded_file:).call
  end

  def initialize(user:, uploaded_file:)
    @user = user
    @uploaded_file = uploaded_file
  end

  def call
    return Result.new(alert: "Please select a file to upload") unless uploaded_file

    extension = File.extname(uploaded_file.original_filename).delete(".").downcase
    unless Upload::SUPPORTED_EXTENSIONS.include?(extension)
      return Result.new(
        alert: "Unsupported file type. Supported: #{Upload::SUPPORTED_EXTENSIONS.join(', ')}"
      )
    end

    temp_path = save_uploaded_file

    upload = Upload.new(
      user: user,
      original_filename: uploaded_file.original_filename,
      file_path: temp_path,
      file_size: uploaded_file.size,
      content_type: uploaded_file.content_type,
      status: :pending
    )

    if upload.save
      UploadProcessingJob.perform_later(upload.id)
      Result.new(upload: upload, notice: "File uploaded successfully. Processing started.")
    else
      FileUtils.rm_f(temp_path)
      Result.new(upload: upload, alert: upload.errors.full_messages.join(", "))
    end
  end

  private

  attr_reader :user, :uploaded_file

  def save_uploaded_file
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
