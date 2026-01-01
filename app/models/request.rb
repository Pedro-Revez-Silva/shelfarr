class Request < ApplicationRecord
  belongs_to :book
  belongs_to :user
  has_many :downloads, dependent: :destroy
  has_many :search_results, dependent: :destroy

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

  validates :status, presence: true

  scope :active, -> { where(status: [ :pending, :searching, :downloading, :processing ]) }
  scope :needs_attention, -> { where(attention_needed: true) }
  scope :retry_due, -> { not_found.where("next_retry_at <= ?", Time.current) }
  scope :for_user, ->(user) { where(user: user) }
  scope :processable, -> { pending.order(created_at: :asc) }
  scope :with_issues, -> { where(attention_needed: true).or(where(status: :failed)) }

  def mark_for_attention!(description)
    update!(attention_needed: true, issue_description: description)
  end

  def clear_attention!
    update!(attention_needed: false, issue_description: nil)
  end

  def complete!
    update!(status: :completed, completed_at: Time.current)
    ActivityTracker.track("request.completed", trackable: self, user: user)
  end

  # Schedule retry with exponential backoff
  # Formula: min(base_delay * 2^retry_count, max_delay)
  def schedule_retry!
    max_retries = SettingsService.get(:max_retries)

    with_lock do
      if retry_count >= max_retries
        flag_max_retries_exceeded!
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

  # Flag request when max retries exceeded
  def flag_max_retries_exceeded!
    increment!(:retry_count)
    update!(
      status: :not_found,
      attention_needed: true,
      issue_description: "Maximum retry attempts (#{SettingsService.get(:max_retries)}) exceeded. Manual intervention required."
    )
  end

  # Re-queue a not_found request back to pending
  def requeue!
    update!(status: :pending, next_retry_at: nil)
  end

  # Retry now - reset for immediate processing
  def retry_now!
    update!(
      status: :pending,
      next_retry_at: nil,
      attention_needed: false,
      issue_description: nil
    )
  end

  # Cancel/fail request permanently
  def cancel!
    update!(
      status: :failed,
      attention_needed: false,
      issue_description: nil
    )
  end

  # Check if request can be retried
  def can_retry?
    pending? || not_found? || failed?
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

    ActiveRecord::Base.transaction do
      search_results.where.not(id: search_result.id).update_all(status: :rejected)
      search_result.update!(status: :selected)

      download = downloads.create!(
        name: search_result.title,
        size_bytes: search_result.size_bytes,
        status: :queued
      )

      update!(status: :downloading)
      DownloadJob.perform_later(download.id)
      download
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

  private

  def set_default_language
    self.language ||= SettingsService.get(:default_language)
  end
end
