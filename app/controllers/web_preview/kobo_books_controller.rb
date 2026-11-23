# frozen_string_literal: true

class WebPreview::KoboBooksController < WebPreview::APIController
  include KoboCataloguePages

  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  PAGE = /\A[1-9]\d{0,5}\z/
  COPY_CHANGED = "This book's private copy changed after the page was shown. Review it and choose again."

  before_action :set_book, except: :catalogue
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def catalogue
    return render_error("invalid_request", :bad_request) unless catalogue_query?

    account = params[:id].to_s.match?(IDENTIFIER) && Kobo::HouseholdAccess.visible_accounts(Current.user).find_by(id: params[:id])
    return render_error("catalogue_not_found", :not_found) unless account

    load_catalogue(account)
    render json: { account: web_preview_account_id, catalogue: json.catalogue(account, books: @books, filter: @filter, page: @page, more: @more, count: @count, sendable_count: @sendable_count) }
  end

  def show
    render_book
  end

  def prepare
    copy = shown_copy
    return render_error("invalid_request", :bad_request) if copy == :invalid
    return render_copy_changed unless copy == WebPreview::KoboAccountJson.copy_version(@book.ready_file)

    Kobo::BookCache.request!(@book, Current.user)
    render_book(notice: "Preparing a private copy. This usually takes under a minute.")
  rescue Kobo::BookCache::Failure => error
    render_refusal("prepare_refused", KoboAccountBookFile::ERROR_MESSAGES.fetch(error.code, "This copy can't be prepared."))
  rescue Kobo::HouseholdAccess::Denied
    render_error("kobo_book_not_found", :not_found)
  end

  def deliver
    copy = shown_copy
    reader_id = request.request_parameters["reader_id"]
    return render_error("invalid_request", :bad_request) if copy == :invalid || !(reader_id.is_a?(String) && reader_id.match?(IDENTIFIER))

    device = Current.user.kobo_devices.find_by(id: reader_id)
    return render_error("reader_not_found", :not_found) unless device

    file = @book.ready_file
    return render_refusal("deliver_refused", "Prepare a private copy of this book first.") unless @book.deliverable? && file
    return render_copy_changed unless copy == WebPreview::KoboAccountJson.copy_version(file)

    return render_error("kobo_book_not_found", :not_found) unless still_granted?

    device.send_account_book!(file, share: @grant.share)
    render_book(notice: "Queued for #{device.name}. Sync that Kobo over Wi-Fi to download it.")
  rescue KoboPublication::Unavailable => error
    render_refusal("deliver_refused", error.message)
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotFound
    still_granted? ? render_copy_changed : render_error("kobo_book_not_found", :not_found)
  end

  private

  def set_book
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(IDENTIFIER)

    @book = Kobo::HouseholdAccess.visible_books(Current.user).find_by(id: params[:id])
    @grant = @book && Kobo::HouseholdAccess.grant(Current.user, @book.kobo_account)
    render_error("kobo_book_not_found", :not_found) unless @grant
  end

  def still_granted?
    return false unless KoboAccountBook.exists?(@book.id)

    grant = Kobo::HouseholdAccess.grant(Current.user, @book.kobo_account)
    grant.present? && grant.share == @grant.share
  end

  def catalogue_query?
    (params[:filter].nil? || %w[all sendable].include?(params[:filter])) && (params[:page].nil? || params[:page].to_s.match?(PAGE))
  end

  def shown_copy
    body = request.request_parameters
    return :invalid unless body.key?("copy")

    value = body["copy"]
    value.nil? || value.is_a?(String) ? value : :invalid
  end

  def json
    WebPreview::KoboAccountJson.new(Current.user, view: helpers)
  end

  def render_book(notice: nil, status: :ok)
    render json: { account: web_preview_account_id, book: json.book(@book.reload, @grant), notice: notice }.compact, status: status
  end

  def render_refusal(code, message, status: :unprocessable_entity)
    render json: { account: web_preview_account_id, error: code, message: message, book: json.book(@book.reload, @grant) }, status: status
  end

  def render_copy_changed
    render_refusal("copy_changed", COPY_CHANGED, status: :conflict)
  end
end
