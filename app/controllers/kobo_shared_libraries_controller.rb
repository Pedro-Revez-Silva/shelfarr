# frozen_string_literal: true

# Catalogues that other Shelfarr users explicitly shared with the signed-in
# user. Owners manage their own accounts in KoboAccountsController instead.
class KoboSharedLibrariesController < ApplicationController
  include KoboCataloguePages

  before_action :prevent_caching

  def index
    @shares = Current.user.received_kobo_account_shares.effective.includes(kobo_account: :user).order(:created_at)
    @counts = KoboAccountBook.where(kobo_account_id: @shares.map(&:kobo_account_id)).sendable.group(:kobo_account_id).count
  end

  def show
    @account = Kobo::HouseholdAccess.visible_accounts(Current.user).find(params[:id])
    return redirect_to(kobo_account_path(@account)) if @account.user_id == Current.user.id

    load_catalogue(@account)
  end
end
