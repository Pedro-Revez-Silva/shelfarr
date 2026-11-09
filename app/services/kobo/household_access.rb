# frozen_string_literal: true

module Kobo
  # The single permission rule for household Kobo catalogues. Every boundary
  # (catalogue, detail, cover, prepare, queue, sync, metadata, state and file
  # bytes) asks this module again, so a revoked share, a removed account or a
  # soft-deleted user stops access without waiting for cleanup.
  #
  # Viewers are the account owner or the recipient of an effective share.
  # Recipients never receive account credentials; Shelfarr fetches a DRM-free
  # copy on the owner's behalf and delivers it only to the recipient's own reader.
  module HouseholdAccess
    class Denied < StandardError; end
    Grant = Data.define(:account, :viewer, :share) do
      def owner?
        share.nil?
      end
    end

    module_function

    # Catalogue entries the viewer may see: their own and those shared with them.
    def visible_books(viewer)
      KoboAccountBook.where(kobo_account_id: visible_accounts(viewer).select(:id))
    end

    def visible_accounts(viewer)
      return KoboAccount.none unless viewer && !viewer.deleted?

      shared = KoboAccountShare.effective.where(recipient_id: viewer.id).select(:kobo_account_id)
      active = KoboAccount.where(user_id: User.active.select(:id))
      active.where(user_id: viewer.id).or(active.where(id: shared))
    end

    # The viewer's current grant for the account, or nil.
    def grant(viewer, account)
      return unless viewer && account && !viewer.deleted? && account.user && !account.user.deleted?
      return Grant.new(account: account, viewer: viewer, share: nil) if account.user_id == viewer.id

      share = account.kobo_account_shares.effective.find_by(recipient_id: viewer.id)
      Grant.new(account: account, viewer: viewer, share: share) if share
    end

    def grant!(viewer, account)
      grant(viewer, account) || raise(Denied)
    end

    # A private delivery is served only while every condition still holds: the
    # reader's owner is the account owner, or holds the very share that queued
    # it (a later re-grant does not revive it); the title is still an eligible
    # purchase; and its cached copy is still ready.
    def delivery_allowed?(delivery)
      book = delivery.kobo_account_book
      file = delivery.kobo_account_book_file
      device = delivery.kobo_device
      return false unless book && file&.ready? && file.kobo_account_book_id == book.id && device && book.deliverable?

      current = grant(device.user, book.kobo_account)
      return false unless current

      current.owner? ? delivery.kobo_account_share_id.nil? : current.share.id == delivery.kobo_account_share_id
    end
  end
end
