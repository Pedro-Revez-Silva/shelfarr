# frozen_string_literal: true

class WebPreview::UploadsController < WebPreview::APIController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  PER_PAGE = 50
  DISABLED = "Uploads are not currently enabled."

  before_action :require_upload_access, only: [ :request_context, :create ]

  def index
    uploads = policy_scope(Upload)
    total = uploads.count
    total_pages = [ (total.to_f / PER_PAGE).ceil, 1 ].max
    page = Integer(params[:page].to_s, exception: false).to_i.clamp(1, total_pages)
    items = uploads.includes(:request).offset((page - 1) * PER_PAGE).limit(PER_PAGE)
    render json: {
      account: web_preview_account_id,
      can_upload: allowed_to?(:new?, Upload),
      formats: WebPreview::UploadJson.formats,
      max_bytes: UploadCreator::MAX_UPLOAD_BYTES,
      page: page, per_page: PER_PAGE, total: total, total_pages: total_pages,
      items: items.map { |upload| WebPreview::UploadJson.new(upload, viewer: Current.user).as_json }
    }
  end

  def request_context
    request = fulfilment_request(params[:request_id])
    refusal = UploadRequestContext.refusal(request, user: Current.user)
    book = request.book
    render json: {
      account: web_preview_account_id,
      request: {
        id: request.id.to_s, title: book.title.to_s.first(300), author: book.author.presence&.first(300),
        book_type: WebPreview::UploadJson::BOOK_TYPES.include?(book.book_type) ? book.book_type : nil,
        open: refusal.nil?, message: refusal&.message
      }
    }
  end

  def create
    files = submitted_files
    return render_error("invalid_request", :bad_request, message: "Send the files as a form upload.") unless files

    request = params[:request_id].present? ? fulfilment_request(params[:request_id]) : nil
    refusal = request && UploadRequestContext.refusal(request, user: Current.user)
    return render_error("upload_closed", :conflict, message: refusal.message) if refusal

    result = UploadCreator.call_many(user: Current.user, uploaded_files: files, request: request, skip_unsupported: params[:upload_mode] == "folder")
    return render_error("upload_rejected", :unprocessable_entity, message: result.alert.to_s) unless result.success?

    uploads = result.uploads || [ result.upload ].compact
    render status: :created, json: {
      account: web_preview_account_id,
      notice: result.notice, alert: result.alert,
      uploads: uploads.map { |upload| upload.id.to_s },
      request_id: request&.id&.to_s
    }.compact
  end

  private

  def require_upload_access
    render_error("uploads_disabled", :forbidden, message: DISABLED) unless allowed_to?(:new?, Upload)
  end

  def fulfilment_request(value)
    raise ActiveRecord::RecordNotFound unless value.is_a?(String) && value.match?(IDENTIFIER)

    request = Request.includes(:book).find(value)
    raise ActiveRecord::RecordNotFound if UploadRequestContext.refusal(request, user: Current.user)&.reason == :not_owner

    request
  end

  def submitted_files
    value = params[:files].presence || params[:file]
    files = value.is_a?(Array) ? value : [ value ]
    files = files.compact_blank
    return [] if files.empty?

    files if files.all?(ActionDispatch::Http::UploadedFile)
  end
end
