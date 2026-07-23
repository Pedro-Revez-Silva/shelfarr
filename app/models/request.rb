require "digest"
require "uri"

class Request < ApplicationRecord
  class CancellationBlockedError < StandardError; end
  class SearchRefreshBlockedError < StandardError; end

  UPLOAD_FULFILLABLE_STATUSES = %w[
    pending
    searching
    awaiting_purchase
    not_found
    downloading
  ].freeze

  DIRECT_RECOVERY_COLUMNS = %w[
    direct_reservation_token
    direct_staging_path
    direct_staging_device
    direct_staging_inode
    direct_staging_parent_device
    direct_staging_parent_inode
    direct_destination_path
    direct_book_path
    direct_output_root
    direct_output_root_device
    direct_output_root_inode
    direct_publication_kind
    direct_content_manifest
  ].freeze

  CREATED_VIA_VALUES = %w[web api telegram].freeze
  REQUEST_SCOPE_VALUES = %w[single collection].freeze
  MANUAL_MAGNET_GUID_PREFIX = "manual-magnet"
  MANUAL_NZB_GUID_PREFIX = "manual-nzb"

  belongs_to :book
  belongs_to :user
  has_many :request_events, dependent: :destroy
  has_many :downloads, dependent: :destroy
  has_many :search_results, dependent: :destroy
  has_many :store_offers, dependent: :destroy
  has_many :uploads, dependent: :destroy

  before_destroy :prevent_destroy_during_active_acquisition, prepend: true

  SHOW_PAGE_BROADCAST_ATTRIBUTES = %w[
    attention_needed
    completed_at
    issue_description
    next_retry_at
    retry_count
    status
  ].freeze

  enum :status, {
    pending: 0,
    searching: 1,
    not_found: 2,
    downloading: 3,
    processing: 4,
    completed: 5,
    failed: 6,
    awaiting_purchase: 7
  }

  before_validation :set_default_language, on: :create
  before_save :clear_search_claim_when_not_searching
  after_update_commit :broadcast_show_refresh_later_if_needed

  validates :status, presence: true
  validates :created_via, presence: true, inclusion: { in: CREATED_VIA_VALUES }
  validates :request_scope, presence: true, inclusion: { in: REQUEST_SCOPE_VALUES }

  ACTIVE_STATUSES = %w[pending searching downloading processing].freeze
  OPEN_STATUSES = [ *ACTIVE_STATUSES, "awaiting_purchase" ].freeze
  SEARCH_REFRESHABLE_STATUSES = %w[
    pending
    searching
    awaiting_purchase
    not_found
    failed
  ].freeze
  SEARCH_REFRESH_BLOCKING_DOWNLOAD_STATUSES = %w[queued downloading paused].freeze

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :open, -> { where(status: OPEN_STATUSES) }
  scope :needs_attention, -> { where(attention_needed: true) }
  scope :retry_due, -> { not_found.where("next_retry_at <= ?", Time.current) }
  scope :for_user, ->(user) { where(user: user) }
  scope :processable, -> { pending.order(created_at: :asc) }
  scope :with_issues, -> { where(attention_needed: true).or(where(status: :failed)) }

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  def open?
    status.in?(OPEN_STATUSES)
  end

  def mark_for_attention!(description, **attributes)
    self.class.transaction do
      update!(attributes.merge(attention_needed: true, issue_description: description))
      track_diagnostic("attention_flagged", message: description, level: :warn)
    end
    NotificationService.request_attention(self)
  end

  def clear_attention!
    update!(attention_needed: false, issue_description: nil)
  end

  def complete!
    update!(
      status: :completed,
      completed_at: Time.current,
      attention_needed: false,
      issue_description: nil
    )
    ActivityTracker.track("request.completed", trackable: self, user: user)
  end

  # Schedule retry with exponential backoff
  # Formula: min(base_delay * 2^retry_count, max_delay)
  def schedule_retry!
    max_retries = SettingsService.get(:max_retries)

    with_lock do
      if retry_count >= max_retries
        mark_for_attention!(
          "Maximum retry attempts (#{max_retries}) exceeded. Manual intervention required.",
          status: :not_found,
          retry_count: retry_count + 1
        )
        return false
      end

      base_delay_hours = SettingsService.get(:retry_base_delay_hours)
      max_delay_days = SettingsService.get(:retry_max_delay_days)
      max_delay_hours = max_delay_days * 24

      # Exponential backoff: base * 2^retry_count, capped at max
      delay_hours = [ base_delay_hours * (2 ** retry_count), max_delay_hours ].min

      increment!(:retry_count)
      update!(
        status: :not_found,
        next_retry_at: Time.current + delay_hours.hours
      )
    end
    true
  end

  # Re-queue a not_found request back to pending
  def requeue!
    with_search_transition_lock do
      queue_fresh_search_under_lock!(next_retry_at: nil)
    end
  end

  # Discard provider-owned search data and invalidate every in-flight search
  # before a replacement job is enqueued. Manual results remain available.
  def refresh_search!
    with_acquisition_transition_lock do
      unless search_refresh_allowed?
        raise SearchRefreshBlockedError, search_refresh_blocked_message
      end

      queue_fresh_search_under_lock!
      search_results
        .where.not(source: SearchResult::MANUAL_SOURCES)
        .where.not(status: :selected)
        .destroy_all
      store_offers.destroy_all
    end
  end

  # A worker can be killed after atomically claiming a pending request but
  # before publishing results. Completed searches clear search_claimed_at even
  # when their user-facing status remains searching for manual review. Recheck
  # that explicit lease while holding the same generation transition lock used
  # by SearchJob completion, then invalidate the killed worker before making
  # the request eligible for replacement.
  def recover_stale_search!(stale_before:)
    with_search_transition_lock do
      next false unless searching? && search_claimed_at.present? && search_claimed_at <= stale_before

      queue_fresh_search_under_lock!
      true
    end
  end

  # Retry now - reset for immediate processing.
  # If a selected release already failed, keep it blocklisted and try the next
  # eligible candidate before falling back to a fresh search.
  def retry_now!
    if post_processing_recovery_pending?
      return retry_post_processing_now!
    end

    selected_result = search_results.selected.first
    failed_download = selected_result && downloads.where(status: :failed, search_result: selected_result).order(created_at: :desc).first

    if selected_result && failed_download
      reason = "Failed download (manual retry)"
      blocklist_result!(selected_result, reason: reason, download: failed_download)

      if auto_select_enabled? && attempt_next_candidate!(failure_reason: reason, mark_exhausted: false) == :selected_next
        return
      end
    end

    with_search_transition_lock do
      # A retry starts a fresh provider search. Do not keep showing purchase
      # options quoted by the previous search while that retry is queued.
      queue_fresh_search_under_lock!(
        next_retry_at: nil,
        attention_needed: false,
        issue_description: nil
      )
      store_offers.delete_all
    end
  end

  # A handled post-processing failure must retry the durable import owner, not
  # start a fresh provider search while published partial files remain. The
  # owner transfer commits before enqueue, so the recurring recovery watchdog
  # repairs an enqueue crash without allowing the previous job to finalize.
  def retry_post_processing_now!
    retry_job = nil
    outcome = with_acquisition_transition_lock do
      next :not_pending unless post_processing_recovery_pending?
      next :active unless attention_needed?

      download = downloads.completed
        .where.not(post_processing_job_id: [ nil, "" ])
        .order(updated_at: :desc, id: :desc)
        .first
      next :not_pending unless download

      expected_owner = download.post_processing_job_id
      retry_job = PostProcessingJob.new(download.id, 0, expected_owner)
      claimed = Download.where(
        id: download.id,
        status: Download.statuses[:completed],
        post_processing_job_id: expected_owner
      ).update_all(
        post_processing_job_id: retry_job.job_id,
        updated_at: Time.current
      )
      next :superseded unless claimed == 1

      # Clear the handled-failure marker in the same durable transition as the
      # new owner. If enqueue is interrupted, the recurring watchdog now sees
      # an active recovery claim and repairs it. If the replacement worker
      # subsequently fails, its owner-checked failure transition restores the
      # attention state without being overwritten by this caller.
      update!(
        status: :processing,
        attention_needed: false,
        issue_description: nil,
        completed_at: nil
      )
      :claimed
    end
    return outcome unless outcome == :claimed

    retry_job.enqueue ? :post_processing_queued : :post_processing_recovery_pending
  end

  def handle_download_failure!(download, reason:)
    download.update!(status: :failed) unless download.failed?

    blocklisted = blocklist_result!(download.search_result, reason: reason, download: download)

    unless auto_select_enabled?
      manual_message = if blocklisted
        "Download failed: #{reason}. The failed release was blocklisted. Select another release manually."
      else
        "Download failed: #{reason}. Select another release manually."
      end
      mark_for_attention!(manual_message)
      return :manual_review
    end

    attempt_next_candidate!(failure_reason: reason)
  end

  def blocklist_and_select_next!(reason:, search_result: nil)
    target = search_result || search_results.selected.first
    return :no_selected_result unless target

    ActiveRecord::Base.transaction do
      downloads.where(status: [ :queued, :downloading, :paused ]).find_each do |download|
        cancel_download(download)
      end

      blocklist_result!(target, reason: reason)
    end

    attempt_next_candidate!(failure_reason: reason)
  end

  # Cancel/fail request permanently
  # Also cancels any active downloads and removes them from download clients
  def cancel!(allow_direct_recovery: false)
    cancelled_download_ids = with_acquisition_transition_lock do
      raise CancellationBlockedError, upload_cancellation_blocked_message if upload_cancellation_blocked?
      if post_processing_recovery_pending?
        raise CancellationBlockedError, post_processing_recovery_message
      end
      if direct_acquisition_recovery_pending? && !allow_direct_recovery
        raise CancellationBlockedError, direct_acquisition_recovery_message
      end
      if completed?
        raise CancellationBlockedError, "Cannot cancel request in completed status"
      end

      # Claim cancellation in SQLite before doing network I/O. DownloadJob and
      # post-processing compare-and-swaps can no longer start after this commit.
      active_downloads = downloads.where(status: [ :queued, :downloading, :paused ])
      download_ids = active_downloads.pluck(:id)
      active_downloads.update_all(status: Download.statuses[:failed], updated_at: Time.current)

      update!(
        status: :failed,
        attention_needed: false,
        issue_description: nil
      )
      download_ids
    end

    # Never hold Shelfarr's SQLite writer lock across a remote-client call.
    Download.where(id: cancelled_download_ids).includes(:download_client).find_each do |download|
      remove_download_from_client(download)
    end

    NotificationService.request_failed(self)
  end

  # Manual-upload attachment, API cancellation, and destructive web
  # cancellation all use this same transition lock. The UPDATE is deliberately
  # the first statement: PostgreSQL obtains a row lock and SQLite obtains its
  # writer lock before either side checks status or recovery associations.
  # This closes the gap where a cancellation could pass its guard immediately
  # before a pending Upload was inserted.
  def with_acquisition_transition_lock
    self.class.transaction do
      serialize_acquisition_transition!
      reload
      yield self
    end
  end

  # SQLite does not provide row-level SELECT ... FOR UPDATE locking. Making a
  # no-op UPDATE the first statement serializes search state transitions there,
  # while also taking the request row lock on databases that support it.
  def with_search_transition_lock
    self.class.transaction do
      locked = self.class.where(id: id).update_all("search_generation = search_generation")
      raise ActiveRecord::RecordNotFound, "Request is no longer available" unless locked == 1

      reload
      yield self
    end
  end

  def upload_fulfillable?
    status.in?(UPLOAD_FULFILLABLE_STATUSES)
  end

  # Claims destructive web cancellation before the controller talks to a
  # download client or records activity. Persisting a non-fulfillable status
  # and failing active Download rows under the same admission lock prevents a
  # queued upload/direct dispatch from starting in the side-effect window. A
  # process killed after this claim can safely call it again and resume the
  # destroy flow.
  def claim_destructive_cancellation!
    with_acquisition_transition_lock do
      raise CancellationBlockedError, upload_cancellation_blocked_message if upload_cancellation_blocked?
      if post_processing_recovery_pending?
        raise CancellationBlockedError, post_processing_recovery_message
      end
      if direct_acquisition_recovery_pending?
        raise CancellationBlockedError, direct_acquisition_recovery_message
      end
      if completed?
        raise CancellationBlockedError, "Cannot cancel request in completed status"
      end

      now = Time.current
      downloads.where(status: [ :queued, :downloading, :paused ]).update_all(
        status: Download.statuses[:failed],
        updated_at: now
      )
      update!(
        status: :failed,
        attention_needed: false,
        issue_description: nil,
        updated_at: now
      )
    end
  end

  # Cancel a specific download and remove from download client
  def cancel_download(download)
    return unless download.queued? || download.downloading? || download.paused?

    remove_download_from_client(download)
    download.update!(status: :failed)
  end

  def remove_download_from_client(download)
    # Try to remove from download client if we have an external_id
    if download.external_id.present? && download.download_client.present?
      begin
        client = download.download_client.client_instance
        removed = client.remove_torrent(download.external_id, delete_files: true)
        if removed
          Rails.logger.info "[Request] Removed download #{download.id} from #{download.download_client.name}"
        else
          Rails.logger.warn "[Request] Client did not confirm removal for download #{download.id}; scheduling cleanup"
          enqueue_stale_client_cleanup(download)
        end
      rescue => e
        Rails.logger.warn "[Request] Failed to remove download from client: #{e.class}; scheduling cleanup"
        enqueue_stale_client_cleanup(download)
      end
    end
  end

  # Check if request can be retried
  # Allow retry if already in retryable state OR if attention is needed
  def can_retry?
    return false if completed?
    pending? || awaiting_purchase? || not_found? || failed? || attention_needed?
  end

  # Check if request needs manual selection of search results
  def needs_manual_selection?
    searching? && search_results.pending.any?
  end

  # Check if request can be cancelled/deleted
  # Allow cancellation for any request that isn't already completed
  def can_be_cancelled?
    !completed? &&
      !upload_cancellation_blocked? &&
      !post_processing_recovery_pending? &&
      !direct_acquisition_recovery_pending?
  end

  def search_refresh_allowed?
    status.in?(SEARCH_REFRESHABLE_STATUSES) && !search_refresh_acquisition_blocked?
  end

  def search_refresh_blocked_message
    if completed?
      "Cannot refresh search for a completed request."
    elsif downloading? || processing? || search_refresh_acquisition_blocked?
      "Cannot refresh search while an acquisition or library import is active or awaiting recovery."
    else
      "Cannot refresh search from the current request state."
    end
  end

  def upload_cancellation_blocked?
    return false unless persisted?
    return true if uploads.cancellation_blocking.exists?

    upload_ids = uploads.select(:id)
    direct_imports = OwnedMediaImport.cancellation_blocking.where(request_id: id)
    upload_imports = OwnedMediaImport.cancellation_blocking.where(upload_id: upload_ids)
    direct_imports.or(upload_imports).exists?
  end

  def upload_cancellation_blocked_message
    "This request has an upload or Audible backup in progress. " \
      "Wait for it to finish, or retry its recovery, before cancelling the request."
  end

  # A non-nil owner on a completed Download is the durable recovery claim for
  # filesystem publication performed by PostProcessingJob. It is deliberately
  # ignored once the Request is completed so pre-existing installations (where
  # successful jobs retained their owner ID) are not prevented from deleting
  # already-acquired books after upgrading.
  def post_processing_recovery_pending?
    return false unless persisted?
    return true if downloads.completed.where.not(post_processing_cleanup_state: [ nil, "" ]).exists?
    return false if completed?

    downloads.completed.where.not(post_processing_job_id: [ nil, "" ]).exists?
  end

  def post_processing_recovery_message
    "This request has a completed download whose library import is still in progress or awaiting recovery. " \
      "Wait for post-processing recovery to finish before cancelling the request."
  end

  # Direct downloads publish outside the database transaction and retain a
  # durable recovery row while bytes are staged or awaiting finalization.
  # Destroying that row would strand a Book reservation or an already
  # published file with no safe recovery owner.
  def direct_acquisition_recovery_pending?
    predicate = DIRECT_RECOVERY_COLUMNS.map { |column| "#{column} IS NOT NULL" }.join(" OR ")
    downloads.where(predicate).exists?
  end

  def direct_acquisition_recovery_message
    "This request has a direct download awaiting safe recovery. " \
      "Wait for recovery to finish before deleting the request."
  end

  # Check if retry is due
  def retry_due?
    not_found? && next_retry_at.present? && next_retry_at <= Time.current
  end

  def manual_download_allowed?
    !completed? && !processing? && !download_dispatch_in_progress?
  end

  alias_method :manual_magnet_allowed?, :manual_download_allowed?
  alias_method :manual_nzb_allowed?, :manual_download_allowed?

  # Select a search result and initiate download
  # Returns the created Download record
  def select_result!(search_result)
    raise ArgumentError, "Result not downloadable" unless search_result.downloadable?
    raise ArgumentError, "Result does not belong to this request" unless search_result.request_id == id

    with_lock do
      raise ArgumentError, "Cannot replace a download while dispatch is in progress" if download_dispatch_in_progress?

      select_result_under_lock!(search_result)
    end
  end

  def add_manual_magnet!(magnet_link)
    magnet_link = magnet_link.to_s.strip
    raise ArgumentError, "Enter a valid magnet link" unless magnet_link.start_with?("magnet:?")

    info_hash = MagnetLink.info_hash(magnet_link)
    raise ArgumentError, "Enter a magnet link with a valid info hash" if info_hash.blank?

    with_lock do
      raise ArgumentError, "Cannot add a magnet link to a completed request" if completed?
      raise ArgumentError, "Cannot add a magnet link while post-processing is active" if processing?
      raise ArgumentError, "Cannot replace a download while dispatch is in progress" if download_dispatch_in_progress?

      search_result = search_results.find_or_initialize_by(guid: manual_magnet_guid(info_hash))
      search_result.assign_attributes(
        title: "Manual magnet for #{book.display_name}",
        magnet_url: magnet_link,
        source: SearchResult::SOURCE_MANUAL_MAGNET,
        indexer: "Manual Magnet",
        seeders: nil,
        leechers: nil,
        download_url: nil,
        status: :pending
      )
      search_result.save!

      select_result_under_lock!(search_result)
    end
  end

  def add_manual_nzb!(nzb_url)
    nzb_url = nzb_url.to_s.strip
    raise ArgumentError, "Enter a valid HTTP(S) NZB URL" unless valid_manual_nzb_url?(nzb_url)

    with_lock do
      raise ArgumentError, "Cannot add an NZB URL to a completed request" if completed?
      raise ArgumentError, "Cannot add an NZB URL while post-processing is active" if processing?
      raise ArgumentError, "Cannot replace a download while dispatch is in progress" if download_dispatch_in_progress?

      search_result = search_results.find_or_initialize_by(guid: manual_nzb_guid(nzb_url))
      search_result.assign_attributes(
        title: "Manual NZB for #{book.display_name}",
        download_url: nzb_url,
        magnet_url: nil,
        source: SearchResult::SOURCE_MANUAL_NZB,
        indexer: "Manual NZB",
        seeders: nil,
        leechers: nil,
        status: :pending
      )
      search_result.save!

      select_result_under_lock!(search_result)
    end
  end

  def next_retry_in_words
    return nil unless next_retry_at.present? && next_retry_at > Time.current

    distance = next_retry_at - Time.current
    if distance < 1.hour
      "#{(distance / 60).round} minutes"
    elsif distance < 1.day
      "#{(distance / 1.hour).round} hours"
    else
      "#{(distance / 1.day).round} days"
    end
  end

  def effective_language
    language.presence || SettingsService.get(:default_language)
  end

  def language_display_name
    info = ReleaseParserService.language_info(effective_language)
    info ? info[:name] : effective_language
  end

  def broadcast_show_refresh_later
    broadcast_refresh_later_to self
  end

  private

  def queue_fresh_search_under_lock!(**attributes)
    update!(
      {
        attention_needed: false,
        issue_description: nil
      }.merge(attributes).merge(
        status: :pending,
        search_generation: search_generation + 1,
        search_claimed_at: nil
      )
    )
  end

  def clear_search_claim_when_not_searching
    self.search_claimed_at = nil unless searching?
  end

  def prevent_destroy_during_active_acquisition
    serialize_acquisition_transition!

    message = if upload_cancellation_blocked?
      upload_cancellation_blocked_message
    elsif post_processing_recovery_pending?
      post_processing_recovery_message
    elsif direct_acquisition_recovery_pending?
      direct_acquisition_recovery_message
    end
    return unless message

    errors.add(:base, message)
    throw :abort
  end

  def serialize_acquisition_transition!
    locked = self.class.where(id: id).update_all(updated_at: Time.current)
    raise ActiveRecord::RecordNotFound, "Request is no longer available" unless locked == 1
  end

  def select_result_under_lock!(search_result)
    downloads.where(status: [ :queued, :downloading, :paused ]).find_each do |download|
      cancel_download(download)
    end

    if search_result.blocklisted?
      search_result.clear_blocklist!
      track_diagnostic(
        "blocklist_overridden",
        message: "Blocklist overridden for selected release",
        level: :warn,
        user_visible: true,
        details: {
          search_result_id: search_result.id,
          title: search_result.title
        }
      )
    end

    search_results.where.not(id: search_result.id).update_all(status: :rejected)
    search_result.update!(status: :selected)

    download = downloads.create!(
      name: search_result.title,
      size_bytes: search_result.size_bytes,
      search_result: search_result,
      status: :queued
    )

    update!(
      status: :downloading,
      next_retry_at: nil,
      attention_needed: false,
      issue_description: nil
    )

    track_diagnostic(
      "download_queued",
      download: download,
      message: "Download queued from manual result selection",
      details: {
        search_result_id: search_result.id,
        title: search_result.title,
        trigger: "manual_select"
      }
    )

    download_id = download.id
    monitor_direct_download = search_result.direct_download?
    ActiveRecord.after_all_transactions_commit do
      DownloadJob.perform_later(download_id)
      begin
        DownloadMonitorJob.ensure_running! if monitor_direct_download
      rescue StandardError => e
        Rails.logger.error "[Request] Failed to start direct download monitor: #{e.class}"
      end
    end
    download
  end

  def broadcast_show_refresh_later_if_needed
    broadcast_show_refresh_later if (previous_changes.keys & SHOW_PAGE_BROADCAST_ATTRIBUTES).any?
  end

  def attempt_next_candidate!(failure_reason:, mark_exhausted: true)
    search_results.rejected.not_blocklisted.update_all(
      status: SearchResult.statuses[:pending],
      updated_at: Time.current
    )

    selection = AutoSelectService.call(self)
    if selection.success?
      track_diagnostic(
        "fallback_selected",
        message: "Selected the next eligible release after a failed download",
        user_visible: true,
        details: {
          search_result_id: selection.search_result&.id,
          title: selection.search_result&.title,
          failure_reason: failure_reason
        }
      )
      return :selected_next
    end

    mark_candidate_exhausted!(failure_reason, selection.reason) if mark_exhausted
    :exhausted
  end

  def mark_candidate_exhausted!(failure_reason, selection_reason)
    blocklisted_count = search_results.blocklisted.count
    remaining_reason = selection_reason.to_s.humanize.downcase
    mark_for_attention!(
      "Download failed: #{failure_reason}. No suitable alternative release found - " \
        "#{blocklisted_count} release(s) blocklisted, remaining results #{remaining_reason}. " \
        "Select a release manually or refresh the search.",
      status: :not_found
    )
  end

  def blocklist_result!(search_result, reason:, download: nil)
    return false unless search_result
    return false if search_result.blocklisted?

    search_result.blocklist!(reason)
    track_diagnostic(
      "release_blocklisted",
      download: download,
      message: "Blocklisted release after failed download",
      level: :warn,
      user_visible: true,
      details: {
        search_result_id: search_result.id,
        title: search_result.title,
        reason: reason
      }
    )
    true
  end

  def auto_select_enabled?
    SettingsService.get(:auto_select_enabled, default: false)
  end

  def track_diagnostic(event_type, message: nil, level: :info, download: nil, details: {}, user_visible: false)
    RequestEvent.record!(
      request: self,
      download: download,
      event_type: event_type,
      source: "request",
      message: message,
      level: level,
      details: details,
      user_visible: user_visible
    )
  end

  def manual_magnet_guid(info_hash)
    "#{MANUAL_MAGNET_GUID_PREFIX}:#{info_hash}"
  end

  def manual_nzb_guid(nzb_url)
    "#{MANUAL_NZB_GUID_PREFIX}:#{Digest::SHA256.hexdigest(nzb_url)}"
  end

  def valid_manual_nzb_url?(value)
    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def download_dispatch_in_progress?
    downloads.downloading.where(external_id: [ nil, "" ]).exists?
  end

  def search_refresh_acquisition_blocked?
    downloads.where(status: SEARCH_REFRESH_BLOCKING_DOWNLOAD_STATUSES).exists? ||
      upload_cancellation_blocked? ||
      post_processing_recovery_pending? ||
      direct_acquisition_recovery_pending?
  end

  def enqueue_stale_client_cleanup(download)
    StaleClientDispatchCleanupJob.perform_later(download.download_client_id, download.external_id)
  rescue StandardError => e
    Rails.logger.error "[Request] Failed to enqueue stale client cleanup for download #{download.id}: #{e.class}"
  end

  def set_default_language
    self.language ||= SettingsService.get(:default_language)
  end
end
