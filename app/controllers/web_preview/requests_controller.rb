# frozen_string_literal: true

class WebPreview::RequestsController < WebPreview::APIController
  include ConsumerWebPublication

  class WithdrawalChanged < StandardError; end

  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  FILTER_STATUSES = %w[active pending searching not_found downloading processing completed failed awaiting_purchase].freeze
  MANUAL_FIELDS = { "magnet" => :magnet_url, "nzb" => :nzb_url }.freeze
  RETRY_MESSAGES = {
    post_processing_recovery_pending: "The retry could not be queued now. Shelfarr kept its recovery claim and will retry by itself.",
    active: "A recovery for this request is already running.",
    superseded: "Another recovery attempt took over this request."
  }.freeze
  NOT_RETRYABLE = "This request can't be retried in its current state."
  ACTIVE_DOWNLOADS = %w[queued downloading paused].freeze
  READ_ATTEMPTS = 3
  NOT_CHOOSABLE = "This copy can no longer be chosen. The page shows what can be chosen now."
  COPIES_CHANGED = "The chosen copy changed since this page was read. The page now shows the current copies; choose again if you still want this one."
  WITHDRAWAL_CHANGED = "This request changed since the page was read. The page now shows it as it is; check what removing it does and choose again."
  REPLACEMENT_UNCONFIRMED = "This book is already in the library. Confirm that this copy replaces the library file, then choose it again."

  before_action :require_admin, only: [ :selection, :search, :retry, :manual ]

  def index
    status = params[:status].presence
    return render_error("invalid_request", :bad_request) unless status.nil? || FILTER_STATUSES.include?(status)

    listing = RequestListing.new(user: Current.user, status: status, attention: params[:attention], query: params[:q], page: params[:page], includes: [ :book, :downloads ])
    render json: {
      account: web_preview_account_id,
      scope: listing.everyone? ? "all" : "own",
      filter: { status: status, attention: params[:attention] == "true", q: listing.query.presence },
      counts: { attention: listing.attention_count, active: listing.active_count },
      page: listing.page, per_page: RequestListing::PER_PAGE, total: listing.total_count, total_pages: listing.total_pages,
      items: listing.requests.map { |request| projection(request).summary }
    }
  end

  def show
    detail = Request.uncached { coherent_detail(identifier(params[:id])) }
    return render_error("server_busy", :service_unavailable) unless detail

    render json: { account: web_preview_account_id, request: detail }
  end

  def selection
    request = Request.find(identifier(params[:id]))
    result = request.search_results.find(identifier(params[:result_id]))
    refusal = request.with_lock do
      result.reload
      params.key?(:expected_revision) ? choose_copy(request, result) : choose_waiting_copy(request, result)
    end
    code, status, message = refusal
    code ? render_error(code, status, message: message) : render_action(request)
  rescue ArgumentError => error
    render_error("not_selectable", :conflict, message: error.message.first(300))
  end

  def search
    request = Request.find(identifier(params[:id]))
    request.refresh_search!
    SearchJob.perform_later(request.id)
    render_action(request)
  rescue Request::SearchRefreshBlockedError => error
    render_error("search_blocked", :conflict, message: error.message.first(300))
  end

  def cancel
    request = Request.for_user(Current.user).find(identifier(params[:id]))
    return render_error("cannot_cancel", :conflict, message: cancel_message(request)) unless request.can_be_cancelled?

    request.cancel!
    render_action(request)
  rescue Request::CancellationBlockedError => error
    render_error("cannot_cancel", :conflict, message: error.message.first(300))
  end

  def retry
    request = Request.find(identifier(params[:id]))
    return render_error("cannot_retry", :conflict, message: NOT_RETRYABLE) unless request.can_retry?

    message = RETRY_MESSAGES[request.retry_now!]
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: request.reload.status }, message: message }.compact
  end

  def remove
    request = visible_requests.find(identifier(params[:id]))
    if Current.user.admin?
      remove_as_admin(request)
    elsif request.completed?
      remove_own_history(request)
    else
      return render_error("cannot_remove", :conflict, message: "Only finished requests can be deleted.")
    end
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: "removed" } }
  rescue ActiveRecord::RecordNotDestroyed, Request::CancellationBlockedError => error
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render_error("cannot_remove", :conflict, message: message.to_s.first(300).presence || request.upload_cancellation_blocked_message)
  end

  def withdraw
    return render_error("request_changed", :conflict, message: WITHDRAWAL_CHANGED) if Current.user.admin?

    revision = params[:expected_revision]
    remove_client_jobs = params[:remove_client_jobs]
    return render_error("invalid_request", :bad_request) unless revision.is_a?(String) && [ true, false ].include?(remove_client_jobs)

    request = Request.for_user(Current.user).find(identifier(params[:id]))
    outcome = RequestWithdrawal.call(request, remove_client_jobs: remove_client_jobs) do |locked|
      raise WithdrawalChanged unless withdrawal_admitted?(locked, revision)
    end
    return render_action(request) unless outcome == :removed

    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: "removed" } }
  rescue WithdrawalChanged
    render_error("request_changed", :conflict, message: WITHDRAWAL_CHANGED)
  rescue ActiveRecord::RecordNotDestroyed, Request::CancellationBlockedError => error
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    render_error("cannot_remove", :conflict, message: message.to_s.first(300).presence || request.upload_cancellation_blocked_message)
  end

  def manual
    request = Request.find(identifier(params[:id]))
    field = MANUAL_FIELDS[params[:kind]]
    link = field && params[field]
    return render_error("invalid_request", :unprocessable_entity) unless link.is_a?(String)

    replace = params[:replace_library_file] == true
    field == :magnet_url ? request.add_manual_magnet!(link, replace_library_file: replace) : request.add_manual_nzb!(link, replace_library_file: replace)
    render_action(request)
  rescue ArgumentError => error
    render_error("manual_rejected", :unprocessable_entity, message: error.message.first(300))
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    render_error("manual_rejected", :unprocessable_entity, message: "The link could not be queued. Try again.")
  end

  private

  def coherent_detail(id)
    READ_ATTEMPTS.times do
      seen = Current.user.admin? ? WebPreview::RequestJson.copies_revision(visible_requests.find(id)) : nil
      request = visible_requests.includes(:book, :downloads, :search_results).find(id)
      detail = projection(request).detail(store_offers: StoreProviderRegistry.visible_offers_for(request).best_first.to_a, copies_revision: seen)
      return detail if seen.nil? || seen == WebPreview::RequestJson.copies_revision(request)
    end
    nil
  end

  def choose_waiting_copy(request, result)
    raise ArgumentError, NOT_CHOOSABLE unless WebPreview::BookPage.choosing_allowed?(request) && result.downloadable?

    request.select_result!(result)
    nil
  end

  def choose_copy(request, result)
    return [ "invalid_request", :bad_request ] unless params[:expected_revision].is_a?(String)
    return if result.selected? && request.downloads.where(search_result: result, status: ACTIVE_DOWNLOADS).exists?
    return [ "copies_changed", :conflict, COPIES_CHANGED ] unless params[:expected_revision] == WebPreview::RequestJson.copies_revision(request)

    replace = params[:replace_library_file] == true
    return [ "replacement_unconfirmed", :conflict, REPLACEMENT_UNCONFIRMED ] if request.book.acquired? && !replace
    raise ArgumentError, NOT_CHOOSABLE unless result.downloadable?

    request.select_result!(result, replace_library_file: replace)
    nil
  end

  def withdrawal_admitted?(locked, revision)
    !locked.direct_acquisition_recovery_pending? && User.find(Current.user.id).user? && revision == WebPreview::RequestJson.withdrawal_offer(locked).fetch(:revision)
  end

  def require_admin
    render_error("not_found", :not_found) unless Current.user.admin?
  end

  def visible_requests
    Current.user.admin? ? Request.all : Request.for_user(Current.user)
  end

  def identifier(value)
    raise ActiveRecord::RecordNotFound unless value.is_a?(String) && value.match?(IDENTIFIER)

    value
  end

  def render_action(request)
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: request.reload.status } }
  end

  def projection(request)
    WebPreview::RequestJson.new(request, viewer: Current.user, routes: self, opens_in_browser: ->(book) { opens_in_browser?(book) })
  end

  def opens_in_browser?(book)
    Consumer::Publication.new(book, user: Current.user, routes: self, reader_formats: web_reader_formats).representation[:assets].any?
  end

  def remove_as_admin(request)
    completed = request.completed?
    book = request.book
    request.remove_as_admin!
    ActivityTracker.track(completed ? "request.deleted" : "request.cancelled", trackable: request)
    book.destroy if book.requests.reload.empty? && !book.acquisition_blocked?
  end

  def remove_own_history(request)
    book = request.book
    request.destroy_completed_history!
    ActivityTracker.track("request.deleted", trackable: request)
    book.destroy! if book.requests.empty? && !book.acquisition_blocked?
  end

  def cancel_message(request)
    return request.upload_cancellation_blocked_message if request.upload_cancellation_blocked?
    return "This request has already finished." if request.completed?

    "This request is being finished on the server and can't be cancelled now."
  end
end
