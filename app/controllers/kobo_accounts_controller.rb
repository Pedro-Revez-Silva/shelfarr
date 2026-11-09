# frozen_string_literal: true

class KoboAccountsController < ApplicationController
  include KoboCataloguePages

  before_action :prevent_caching
  before_action :set_account, only: [ :show, :poll, :sync, :destroy ]

  def index
    @accounts = Current.user.kobo_accounts.includes(:kobo_account_shares).order(created_at: :desc)
    @received_shares = Current.user.received_kobo_account_shares.effective.includes(kobo_account: :user).order(:created_at)
  end

  def create
    account = Kobo::ConnectionManager.start(user: Current.user, name: params[:name].to_s.first(80))
    redirect_to kobo_account_path(account)
  rescue Kobo::ConnectionManager::LimitReached
    redirect_to kobo_accounts_path, alert: "Too many connections or recent sign-in attempts. Remove unused connections or wait a minute."
  rescue ActiveRecord::RecordInvalid
    redirect_to kobo_accounts_path, alert: "Enter an account name of up to 80 characters."
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
    redirect_to kobo_accounts_path, alert: "This connection was removed before sign-in finished."
  end

  def show
    load_catalogue(@account)
    @shares = @account.kobo_account_shares.includes(:recipient).order(:created_at)
    @share_candidates = User.active.where.not(id: [ Current.user.id, *@shares.map(&:recipient_id) ]).order(:name, :username)
  end

  def poll
    result = Kobo::ConnectionManager.poll(@account)
    result = :pending if result == :approved && @account.sync_active? && params[:phase] == "catalogue"
    if request.format.json?
      render json: { status: result == :approved ? "approved" : result.to_s,
        redirect_url: result == :pending ? nil : kobo_account_path(@account) }
    else
      redirect_to kobo_account_path(@account)
    end
  end

  def sync
    queued = Kobo::ConnectionManager.request_catalogue(@account)
    redirect_to kobo_account_path(@account), notice: queued ? "Catalogue refresh queued." : "A refresh is already running, or this account needs sign-in."
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
    redirect_to kobo_accounts_path, alert: "This connection changed. Try again."
  end

  def destroy
    begin
      @account.with_lock { @account.destroy! }
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info("[Kobo] Connection was already removed")
    end
    redirect_to kobo_accounts_path, notice: "Kobo connection, its private catalogue, copies and shares removed from Shelfarr. Books already on Kobo readers are unchanged."
  end

  private

  def set_account
    @account = Current.user.kobo_accounts.find(params[:id])
  end
end
