# frozen_string_literal: true

# Catalogues that other Shelfarr users explicitly shared with the signed-in
# user. Owners manage their own accounts in KoboAccountsController instead.
class KoboSharedLibrariesController < ApplicationController
  include KoboCataloguePages

  before_action :prevent_caching
  before_action :open_warm_page

  def index
    @shares = Current.user.received_kobo_account_shares.effective.includes(kobo_account: :user).order(:created_at)
    @counts = KoboAccountBook.where(kobo_account_id: @shares.map(&:kobo_account_id)).sendable.group(:kobo_account_id).count
  end

  def show
    @account = Kobo::HouseholdAccess.visible_accounts(Current.user).find(params[:id])
    return redirect_to(kobo_account_path(@account)) if @account.user_id == Current.user.id

    load_catalogue(@account)
  end

  private

  def open_warm_page
    return unless flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?
    return redirect_to(web_preview_account_section_path(section: "devices", anchor: "kobo-shared")) if action_name == "index"

    account = Kobo::HouseholdAccess.visible_accounts(Current.user).find(params[:id])
    if account.user_id == Current.user.id
      redirect_to web_preview_kobo_account_path(account, **warm_catalogue_query)
    else
      redirect_to web_preview_kobo_shared_path(account, **warm_catalogue_query)
    end
  end
end
