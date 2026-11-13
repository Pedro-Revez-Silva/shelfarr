# frozen_string_literal: true

# One title in a connected account's private catalogue. Only its owner, and
# users the owner explicitly shares the account with, can see it. It is never
# copied into the shared Book library.
class KoboAccountBook < ApplicationRecord
  RIGHTS = %w[drm_free protected unsupported none_offered].freeze

  belongs_to :kobo_account
  # Deliveries are removed before the cached files they reference.
  has_many :kobo_deliveries, dependent: :destroy
  has_many :kobo_account_book_files, dependent: :destroy

  # Titles whose recorded metadata qualifies for delivery (see #deliverable?).
  scope :sendable, -> {
    where(archived: false, ownership_type: "purchased", rights: "drm_free").where.not(media_type: "audiobook").where.not(rights_checked_at: nil)
  }

  validates :entitlement_id, presence: true, uniqueness: { scope: :kobo_account_id }
  validates :title, presence: true, length: { maximum: 4096 }
  validates :media_type, inclusion: { in: %w[ebook audiobook unknown] }
  validates :ownership_type, inclusion: { in: %w[purchased subscription preview unknown] }
  validates :rights, inclusion: { in: RIGHTS }, allow_nil: true
  validates :download_format, inclusion: { in: Kobo::DownloadRights::FORMATS }, allow_nil: true

  # Why this title can, or cannot, be sent to another reader. Only a purchased
  # ebook whose Kobo metadata offers a full EPUB marked SignedNoDrm is
  # eligible: that is the only path verified to deliver a DRM-free file.
  def delivery_eligibility
    return :archived if archived?
    return :audiobook if media_type == "audiobook"
    return :subscription if ownership_type == "subscription"
    return :preview if ownership_type == "preview"
    return :ownership_unknown unless ownership_type == "purchased"
    return :unchecked if rights_checked_at.nil?

    case rights
    when "drm_free" then :eligible
    when "protected" then :protected
    when "unsupported" then :unsupported_format
    else :no_download
    end
  end

  def deliverable?
    delivery_eligibility == :eligible
  end

  def ready_file
    kobo_account_book_files.where(status: "ready").order(fetched_at: :desc, id: :desc).first
  end

  def active_fetch
    kobo_account_book_files.where(status: "fetching", started_at: KoboAccountBookFile::FETCH_LEASE.ago..).order(:id).last
  end

  def latest_failure
    kobo_account_book_files.where(status: "failed").order(:id).last
  end
end
