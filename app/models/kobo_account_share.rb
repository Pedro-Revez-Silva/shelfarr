# frozen_string_literal: true

# An explicit, owner-granted permission for one other Shelfarr user to see a
# connected Kobo account's catalogue and send its eligible DRM-free purchases
# to their own Kobo. Accounts are private until shared. Removing the share
# removes the recipient's deliveries from Shelfarr; it cannot erase copies a
# reader already downloaded. A new grant never revives an earlier delivery.
class KoboAccountShare < ApplicationRecord
  MAX_PER_ACCOUNT = 20

  belongs_to :kobo_account
  belongs_to :recipient, class_name: "User"
  has_many :kobo_deliveries, dependent: :destroy

  validates :recipient_id, uniqueness: { scope: :kobo_account_id }
  validate :recipient_is_another_active_user, on: :create
  validate :share_limit, on: :create

  # Both people must still be active Shelfarr users for a share to apply.
  scope :effective, -> {
    where(recipient_id: User.active.select(:id))
      .where(kobo_account_id: KoboAccount.where(user_id: User.active.select(:id)).select(:id))
  }

  def effective?
    recipient.present? && !recipient.deleted? && kobo_account&.user.present? && !kobo_account.user.deleted?
  end

  private

  def recipient_is_another_active_user
    if recipient.nil? || recipient.deleted?
      errors.add(:recipient, "must be an active Shelfarr user")
    elsif recipient_id == kobo_account&.user_id
      errors.add(:recipient, "must be someone other than the account owner")
    end
  end

  def share_limit
    return unless kobo_account && kobo_account.kobo_account_shares.count >= MAX_PER_ACCOUNT

    errors.add(:base, "An account can be shared with at most #{MAX_PER_ACCOUNT} people")
  end
end
