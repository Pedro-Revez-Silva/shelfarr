# frozen_string_literal: true

class KoboAccountsController < ApplicationController
  before_action :prevent_caching
  before_action :set_account, only: [ :show, :poll, :sync, :destroy ]

  def index
    @accounts = Current.user.kobo_accounts.order(created_at: :desc)
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
    @page = [ params[:page].to_i, 1 ].max
    @books = @account.kobo_account_books.order(:title, :id).offset((@page - 1) * 50).limit(51).to_a
    @more = @books.size > 50
    @books = @books.first(50)
    @count = @account.kobo_account_books.count
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
    @account.destroy!
    redirect_to kobo_accounts_path, notice: "Kobo connection and its private catalogue removed from Shelfarr. Your Kobo readers are unchanged."
  end

  private

  def set_account
    @account = Current.user.kobo_accounts.find(params[:id])
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
