# frozen_string_literal: true

class WebPreview::KoboAccountsController < WebPreview::APIController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  NEW_ACCOUNT_NAME = "My Kobo account"
  DISCONNECTED = "Kobo connection, its private catalogue, copies and shares removed from Shelfarr. Books already on Kobo readers are unchanged."
  CHANGED = "This Kobo connection changed after the page was shown. Review it and choose again."

  before_action :set_account, except: %i[index create]
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def index
    accounts = Current.user.kobo_accounts.includes(:kobo_account_shares).order(created_at: :desc).to_a
    shares = Current.user.received_kobo_account_shares.effective.includes(kobo_account: :user).order(:created_at).to_a
    counts = KoboAccountBook.where(kobo_account_id: shares.map(&:kobo_account_id)).sendable.group(:kobo_account_id).count
    render json: { account: web_preview_account_id, kobo_accounts: accounts.map { |account| json.row(account) },
      received: shares.map { |share| json.received(share, counts.fetch(share.kobo_account_id, 0)) }, new_account: { name: NEW_ACCOUNT_NAME } }
  end

  def create
    name = request.request_parameters["name"]
    return render_error("invalid_request", :bad_request) unless name.is_a?(String)

    @account = Kobo::ConnectionManager.start(user: Current.user, name: name.first(80))
    render_account(status: :created)
  rescue Kobo::ConnectionManager::LimitReached
    render_error("kobo_limit_reached", :unprocessable_entity, message: "Too many connections or recent sign-in attempts. Remove unused connections or wait a minute.")
  rescue ActiveRecord::RecordInvalid
    render_error("invalid_kobo_account", :unprocessable_entity, message: "Enter an account name of up to 80 characters.")
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
    render_error("kobo_account_removed", :conflict, message: "This connection was removed before sign-in finished.")
  end

  def show
    render_account
  end

  def poll
    Kobo::ConnectionManager.poll(@account)
    @account.reload
    render_account
  rescue ActiveRecord::RecordNotFound
    render_missing
  end

  def refresh
    queued = Kobo::ConnectionManager.request_catalogue(@account)
    @account.reload
    queued ? render_account(notice: "Catalogue refresh queued.") : render_refusal("refresh_refused", "A refresh is already running, or this account needs sign-in.")
  rescue ActiveRecord::StaleObjectError
    @account = Current.user.kobo_accounts.find_by(id: @account.id)
    @account ? render_refusal("refresh_refused", "This connection changed. Try again.") : render_missing
  rescue ActiveRecord::RecordNotFound
    render_missing
  end

  def share
    recipient_id = request.request_parameters["recipient_id"]
    return render_error("invalid_request", :bad_request) unless recipient_id.is_a?(String) && recipient_id.match?(IDENTIFIER)

    recipient = User.active.where.not(id: Current.user.id).find_by(id: recipient_id)
    share = @account.kobo_account_shares.new(recipient: recipient)
    if share.save
      render_account(notice: "Shared with #{recipient.name}. They can see this catalogue and send its DRM-free purchases to their own Kobo.")
    else
      render_refusal("share_refused", share.errors.full_messages.to_sentence.presence || "Choose someone to share with.", status: :unprocessable_entity)
    end
  rescue ActiveRecord::RecordNotUnique
    render_refusal("share_refused", "This account is already shared with that person.", status: :unprocessable_entity)
  end

  def unshare
    return render_error("invalid_request", :bad_request) unless params[:share_id].is_a?(String) && params[:share_id].match?(IDENTIFIER)

    share = @account.kobo_account_shares.find_by(id: params[:share_id])
    render_account(notice: share ? stop_sharing(share) : "That person no longer has access.")
  end

  def disconnect
    version = request.request_parameters["version"]
    return render_error("invalid_request", :bad_request) unless version.is_a?(String)

    removed = @account.with_lock do
      next false unless version == WebPreview::KoboAccountJson.version(@account)

      @account.destroy!
    end
    return render_disconnected if removed

    @account.reload
    render_refusal("kobo_account_changed", CHANGED, status: :conflict)
  rescue ActiveRecord::RecordNotFound
    render_disconnected
  end

  private

  def set_account
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(IDENTIFIER)

    @account = Current.user.kobo_accounts.find_by(id: params[:id])
    render_missing unless @account
  end

  def stop_sharing(share)
    name = share.recipient.name
    share.destroy!
    "#{name} can no longer see this catalogue or receive its books. Copies already downloaded to their Kobo stay on that reader."
  rescue ActiveRecord::RecordNotFound
    "That person no longer has access."
  end

  def json
    WebPreview::KoboAccountJson.new(Current.user, view: helpers)
  end

  def render_account(notice: nil, status: :ok)
    render json: { account: web_preview_account_id, kobo_account: shown_detail, notice: notice }.compact, status: status
  end

  def render_refusal(code, message, status: :conflict)
    render json: { account: web_preview_account_id, error: code, message: message, kobo_account: shown_detail }, status: status
  end

  def shown_detail
    detail = json.detail(@account)
    headers["Referrer-Policy"] = "no-referrer" if detail[:activation]
    detail
  end

  def render_missing
    render_error("kobo_account_not_found", :not_found)
  end

  def render_disconnected
    render json: { account: web_preview_account_id, disconnected: @account.id.to_s, notice: DISCONNECTED }
  end
end
