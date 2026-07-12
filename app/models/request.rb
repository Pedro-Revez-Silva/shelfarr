require "digest"
require "uri"

class Request < ApplicationRecord
  CREATED_VIA_VALUES = %w[web api telegram].freeze
  REQUEST_SCOPE_VALUES = %w[single collection].freeze
  MANUAL_MAGNET_GUID_PREFIX = "manual-magnet"
  MANUAL_NZB_GUID_PREFIX = "manual-nzb"

  belongs_to :book
  belongs_to :user
  has_many :request_events, dependent: :destroy
  has_many :downloads, dependent: :destroy
  has_many :search_results, dependent: :destroy
  has_many :uploads, dependent: :destroy

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
    failed: 6
  }

  before_validation :set_default_language, on: :create
  after_update_commit :broadcast_show_refresh_later_if_needed

  validates :status, presence: true
  validates :created_via, presence: true, inclusion: { in: CREATED_VIA_VALUES }
  validates :request_scope, presence: true, inclusion: { in: REQUEST_SCOPE_VALUES }

  ACTIVE_STATUSES = %w[pending searching downloading processing].freeze

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :needs_attention, -> { where(attention_needed: true) }
  scope :retry_due, -> { not_found.where("next_retry_at <= ?", Time.current) }
  scope :for_user, ->(user) { where(user: user) }
  scope :processable, -> { pending.order(created_at: :asc) }
  scope :with_issues, -> { where(attention_needed: true).or(where(status: :failed)) }

  def active?
    status.in?(ACTIVE_STATUSES)
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
    update!(status: :pending, next_retry_at: nil)
  end

  # Retry now - reset for immediate processing.
  # If a selected release already failed, keep it blocklisted and try the next
  # eligible candidate before falling back to a fresh search.
  def retry_now!
    selected_result = search_results.selected.first
    failed_download = selected_result && downloads.where(status: :failed, search_result: selected_result).order(created_at: :desc).first

    if selected_result && failed_download
      reason = "Failed download (manual retry)"
      blocklist_result!(selected_result, reason: reason, download: failed_download)

      if auto_select_enabled? && attempt_next_candidate!(failure_reason: reason, mark_exhausted: false) == :selected_next
        return
      end
    end

    update!(
      status: :pending,
      next_retry_at: nil,
      attention_needed: false,
      issue_description: nil
    )
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
  def cancel!
    ActiveRecord::Base.transaction do
      # Cancel active and paused downloads and remove from download clients
      downloads.where(status: [ :queued, :downloading, :paused ]).each do |download|
        cancel_download(download)
      end

      update!(
        status: :failed,
        attention_needed: false,
        issue_description: nil
      )
    end

    NotificationService.request_failed(self)
  end

  # Cancel a specific download and remove from download client
  def cancel_download(download)
    return unless download.queued? || download.downloading? || download.paused?

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

    download.update!(status: :failed)
  end

  # Check if request can be retried
  # Allow retry if already in retryable state OR if attention is needed
  def can_retry?
    return false if completed?
    pending? || not_found? || failed? || attention_needed?
  end

  # Check if request needs manual selection of search results
  def needs_manual_selection?
    searching? && search_results.pending.any?
  end

  # Check if request can be cancelled/deleted
  # Allow cancellation for any request that isn't already completed
  def can_be_cancelled?
    !completed?
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

  def enqueue_stale_client_cleanup(download)
    StaleClientDispatchCleanupJob.perform_later(download.download_client_id, download.external_id)
  rescue StandardError => e
    Rails.logger.error "[Request] Failed to enqueue stale client cleanup for download #{download.id}: #{e.class}"
  end

  def set_default_language
    self.language ||= SettingsService.get(:default_language)
  end
end
