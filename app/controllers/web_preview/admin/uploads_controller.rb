# frozen_string_literal: true

class WebPreview::Admin::UploadsController < WebPreview::Admin::BaseController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/

  before_action :set_upload

  def retry
    answer(administration.retry)
  end

  def destroy
    answer(administration.destroy)
  end

  def matches
    choices = administration.match_choices(query: params[:q].is_a?(String) ? params[:q] : @upload.parsed_title, page: params[:page].to_s, manual_book: nil)
    return render_error("match_unavailable", :conflict, message: match_unavailable_message) unless choices

    render json: {
      account: web_preview_account_id,
      book_type: @upload.infer_book_type.to_s,
      query: choices.query,
      page: choices.page,
      more: choices.books.size > UploadAdministration::MATCHES_PER_PAGE,
      books: choices.books.first(UploadAdministration::MATCHES_PER_PAGE).map { |book| { id: book.id.to_s, title: book.title.to_s, author: book.author.presence } },
      manual_book: { title: choices.manual_book.title.to_s, author: choices.manual_book.author.to_s }
    }
  end

  def match
    attributes = match_attributes
    return render_error("invalid_request", :bad_request, message: "Choose a book or enter a title.") unless attributes

    answer(administration.match_and_retry(attributes))
  end

  private

  def set_upload
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(IDENTIFIER)

    @upload = Upload.find(params[:id])
  end

  def administration
    UploadAdministration.new(@upload, user: Current.user)
  end

  def answer(outcome)
    case outcome.kind
    when :done, :queue_failed
      render json: { account: web_preview_account_id, outcome: outcome.done? ? success(outcome.message) : failure(outcome.message) }
    when :invalid
      render_error("match_rejected", :unprocessable_entity, message: outcome.message.to_s.first(500))
    else
      render_error("upload_refused", :conflict, message: outcome.message.to_s.first(500))
    end
  end

  def match_attributes
    book_id = params[:book_id]
    return { book_id: book_id } if book_id.is_a?(String) && book_id.match?(IDENTIFIER)
    return if params.key?(:book_id)

    fields = params[:manual_book]
    return unless fields.is_a?(ActionController::Parameters)

    title = fields[:title]
    author = fields[:author]
    return unless title.is_a?(String) && (author.nil? || author.is_a?(String))

    { title: title, author: author }
  end

  def match_unavailable_message
    return "This upload has a reserved library file. Use Retry to reconcile it before changing the matched book." if @upload.failed? && @upload.recovery_state?

    "Only failed standalone uploads without reserved files can be matched."
  end
end
