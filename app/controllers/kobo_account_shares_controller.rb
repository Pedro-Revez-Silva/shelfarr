# frozen_string_literal: true

# Only the account owner can grant or revoke household access. Accounts are
# private by default; nothing is shared until the owner picks a person here.
class KoboAccountSharesController < ApplicationController
  before_action :prevent_caching
  before_action :set_account

  def create
    recipient = User.active.where.not(id: Current.user.id).find_by(id: params[:recipient_id])
    share = @account.kobo_account_shares.new(recipient: recipient)
    if share.save
      redirect_to kobo_account_path(@account, anchor: "sharing"),
        notice: "Shared with #{recipient.name}. They can see this catalogue and send its DRM-free purchases to their own Kobo."
    else
      redirect_to kobo_account_path(@account, anchor: "sharing"), alert: share.errors.full_messages.to_sentence.presence || "Choose someone to share with."
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to kobo_account_path(@account, anchor: "sharing"), alert: "This account is already shared with that person."
  end

  def destroy
    share = @account.kobo_account_shares.find(params[:id])
    name = share.recipient.name
    share.destroy!
    redirect_to kobo_account_path(@account, anchor: "sharing"),
      notice: "#{name} can no longer see this catalogue or receive its books. Copies already downloaded to their Kobo stay on that reader."
  rescue ActiveRecord::RecordNotFound
    redirect_to kobo_account_path(@account, anchor: "sharing"), notice: "That person no longer has access."
  end

  private

  def set_account
    @account = Current.user.kobo_accounts.find(params[:kobo_account_id])
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end
end
