# frozen_string_literal: true

class TelegramPollingJob < ApplicationJob
  SCHEDULE_CACHE_KEY = "telegram_polling/next_run_at"
  POLL_TIMEOUT_SECONDS = 20
  POLL_LIMIT = 20
  POLL_INTERVAL_SECONDS = 1

  queue_as :default
  limits_concurrency key: "telegram_polling", duration: 1.minute, on_conflict: :discard

  class << self
    def ensure_running!
      return unless Integrations::Telegram::Configuration.configured?
      return unless Integrations::Telegram::Configuration.polling?
      return if polling_job_pending?

      next_run_at = Rails.cache.read(SCHEDULE_CACHE_KEY).to_i
      return if next_run_at > Time.current.to_i

      reserve_schedule!
      Rails.logger.info "[TelegramPollingJob] Scheduling polling chain"
      perform_later
    end

    def clear_schedule!
      Rails.cache.delete(SCHEDULE_CACHE_KEY)
    end

    def polling_job_pending?(excluding_active_job_id: nil)
      return false unless solid_queue_adapter?

      scope = SolidQueue::Job.where(class_name: name, finished_at: nil)
      scope = scope.where.not(active_job_id: excluding_active_job_id) if excluding_active_job_id.present?
      scope.exists?
    rescue ActiveRecord::StatementInvalid, NameError
      false
    end

    private

    def reserve_schedule!
      Rails.cache.write(
        SCHEDULE_CACHE_KEY,
        POLL_INTERVAL_SECONDS.seconds.from_now.to_i,
        expires_in: [ POLL_TIMEOUT_SECONDS + 30, 60 ].max.seconds
      )
    end

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform
    unless Integrations::Telegram::Configuration.configured? && Integrations::Telegram::Configuration.polling?
      self.class.clear_schedule!
      return
    end

    poll_once
    schedule_next_run
  rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError => e
    Rails.logger.warn "[TelegramPollingJob] Polling failed: #{e.message}"
    schedule_next_run
  end

  private

  def poll_once
    response = Integrations::Telegram::Client.get_updates(
      offset: next_offset,
      timeout: POLL_TIMEOUT_SECONDS,
      limit: POLL_LIMIT
    )

    Array(response["result"]).each do |payload|
      handle_update(payload)
    end
  end

  def handle_update(payload)
    response = Integrations::Telegram::UpdateProcessor.call(payload: payload)
    return unless response&.deliverable?

    Integrations::Telegram::Client.send_message(
      chat_id: response.chat_id,
      text: response.text,
      reply_markup: response.reply_markup
    )
  rescue Integrations::Telegram::Client::DeliveryError => e
    Rails.logger.warn "[TelegramPollingJob] Failed to send Telegram response: #{e.message}"
  end

  def next_offset
    last_update_id = TelegramUpdate.pluck(Arel.sql("MAX(CAST(update_id AS INTEGER))")).first.to_i
    last_update_id.positive? ? last_update_id + 1 : nil
  end

  def schedule_next_run
    return if self.class.polling_job_pending?(excluding_active_job_id: job_id)

    self.class.send(:reserve_schedule!)
    TelegramPollingJob.set(wait: POLL_INTERVAL_SECONDS.seconds).perform_later
  end
end
