# frozen_string_literal: true

# A private copy of one DRM-free Kobo purchase, bound to the owner's account
# entry and to the exact bytes fetched. Rows never point outside the cache root:
# the storage key is derived from database ids and the file's SHA-256 digest.
# A failed or incomplete fetch creates a failed row and never replaces a ready
# copy. A copy referenced by a delivery is kept until no delivery uses it.
class KoboAccountBookFile < ApplicationRecord
  STATUSES = %w[fetching ready failed].freeze
  FETCH_LEASE = 15.minutes
  STORAGE_KEY = %r{\A\d{1,19}/\d{1,19}/[0-9a-f]{64}\.epub\z}
  ERROR_MESSAGES = {
    "access_revoked" => "Access to this account ended before the copy finished. Nothing was saved.",
    "not_eligible" => "Kobo no longer lists a DRM-free EPUB for this purchase.",
    "reauthorization_required" => "The account owner must reconnect this Kobo account before new copies can be prepared.",
    "provider_unavailable" => "Kobo could not be reached. Try again shortly.",
    "protocol_changed" => "Kobo returned an unexpected response. Any earlier copy has been kept.",
    "download_refused" => "Kobo refused the download. Any earlier copy has been kept.",
    "untrusted_host" => "Kobo offered the file from an address Shelfarr does not trust, so it was not downloaded.",
    "too_large" => "This file is larger than the 250 MiB limit for Kobo delivery.",
    "incomplete" => "The download was incomplete. Any earlier copy has been kept; try again.",
    "invalid_file" => "Kobo's file is not a valid EPUB, so it was not saved.",
    "protected_file" => "This file declares encryption, so Shelfarr cannot send it to another Kobo.",
    "cache_full" => "Shelfarr's private Kobo copy space is full. Try again when space is available.",
    "storage_full" => "The server ran out of disk space. Any earlier copy has been kept.",
    "queue_unavailable" => "The copy could not be queued. Try again.",
    "rate_limited" => "Too many copies were requested in the last hour. Try again later.",
    "timed_out" => "Preparing the copy took too long. Try again."
  }.freeze

  belongs_to :kobo_account_book
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :kobo_deliveries, dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :request_id, presence: true
  validates :error, inclusion: { in: ERROR_MESSAGES.keys }, allow_nil: true
  validates :storage_key, format: { with: STORAGE_KEY }, allow_nil: true
  validates :storage_key, :sha256, :size_bytes, :file_device, :file_inode, presence: true, if: :ready?

  after_destroy_commit :remove_stored_file

  def ready?
    status == "ready"
  end

  def fetching?
    status == "fetching" && started_at.present? && started_at > FETCH_LEASE.ago
  end

  def stale?
    ready? && kobo_revision_id.present? && kobo_account_book.revision_id.present? && kobo_revision_id != kobo_account_book.revision_id
  end

  def error_message
    ERROR_MESSAGES[error]
  end

  private

  # Several rows may name the same bytes after a retry. Remove the file only
  # once nothing else refers to it.
  def remove_stored_file
    return if storage_key.blank? || self.class.where(storage_key: storage_key).exists?

    Kobo::BookCache.remove(storage_key)
  end
end
