class Request < ApplicationRecord
  belongs_to :book
  belongs_to :user
  has_many :request_events, dependent: :destroy
  has_many :downloads, dependent: :destroy
  has_many :search_results, dependent: :destroy

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

  scope :active, -> { where(status: [ :pending, :searching, :downloading, :processing ]) }
  scope :needs_attention, -> { where(attention_needed: true) }
  scope :retry_due, -> { not_found.where("next_retry_at <= ?", Time.current) }
  scope :for_user, ->(user) { where(user: user) }
  scope :processable, -> { pending.order(created_at: :asc) }
  scope :with_issues, -> { where(attention_needed: true).or(where(status: :failed)) }

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

  # Retry now - reset for immediate processing
  # If there's a selected result with a failed download, retry the download
  # Otherwise, restart the search process
  def retry_now!
    selected_result = search_results.selected.first
    failed_download = downloads.where(status: :failed).order(created_at: :desc).first

    if selected_result && failed_download
      # Retry the download - create a new download and queue the job
      download = nil
      ActiveRecord::Base.transaction do
        download = downloads.create!(
          name: selected_result.title,
          size_bytes: selected_result.size_bytes,
          status: :queued
        )

        update!(
          status: :downloading,
          next_retry_at: nil,
          attention_needed: false,
          issue_description: nil
        )
      end

      track_diagnostic(
        "download_queued",
        download: download,
        message: "Download queued for retry from selected result",
        details: {
          search_result_id: selected_result.id,
          title: selected_result.title,
          trigger: "retry"
        }
      )
      DownloadJob.perform_later(download.id)
    else
      # No selected result or failed download - restart search
      update!(
        status: :pending,
        next_retry_at: nil,
        attention_needed: false,
        issue_description: nil
      )
    end
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
        client.remove_torrent(download.external_id, delete_files: true)
        Rails.logger.info "[Request] Removed download #{download.id} from #{download.download_client.name}"
      rescue => e
        Rails.logger.warn "[Request] Failed to remove download from client: #{e.message}"
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

  # Select a search result and initiate download
  # Returns the created Download record
  def select_result!(search_result)
    raise ArgumentError, "Result not downloadable" unless search_result.downloadable?
    raise ArgumentError, "Result does not belong to this request" unless search_result.request_id == id

    download = nil
    ActiveRecord::Base.transaction do
      search_results.where.not(id: search_result.id).update_all(status: :rejected)
      search_result.update!(status: :selected)

      download = downloads.create!(
        name: search_result.title,
        size_bytes: search_result.size_bytes,
        status: :queued
      )

      update!(
        status: :downloading,
        attention_needed: false,
        issue_description: nil
      )
    end

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
    DownloadJob.perform_later(download.id)
    download
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

  def broadcast_show_refresh_later_if_needed
    broadcast_show_refresh_later if (previous_changes.keys & SHOW_PAGE_BROADCAST_ATTRIBUTES).any?
  end

  def track_diagnostic(event_type, message: nil, level: :info, download: nil, details: {})
    RequestEvent.record!(
      request: self,
      download: download,
      event_type: event_type,
      source: "request",
      message: message,
      level: level,
      details: details
    )
  end

  def set_default_language
    self.language ||= SettingsService.get(:default_language)
  end
end
