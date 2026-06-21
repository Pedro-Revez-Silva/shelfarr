# frozen_string_literal: true

class MetadataProviderStatus < ApplicationRecord
  STATUSES = %w[unknown healthy degraded rate_limited auth_failed down].freeze

  validates :provider, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  class << self
    def for_provider(provider)
      find_or_create_by!(provider: provider.to_s) do |record|
        record.status = "unknown"
      end
    end
  end

  def available?
    status != "auth_failed" && !rate_limited?
  end

  def rate_limited?
    rate_limited_until.present? && rate_limited_until.future?
  end

  def record_success!
    update!(
      status: "healthy",
      rate_limited_until: nil,
      last_error: nil,
      last_success_at: Time.current,
      failure_count: 0
    )
  end

  def record_failure!(error)
    update!(
      status: status_for(error),
      rate_limited_until: backoff_until_for(error),
      last_error: error.message,
      last_failure_at: Time.current,
      failure_count: failure_count.to_i + 1
    )
  end

  private

  def status_for(error)
    return "rate_limited" if rate_limit_error?(error)
    return "auth_failed" if auth_error?(error)
    return "down" if connection_error?(error)

    "degraded"
  end

  def backoff_until_for(error)
    return nil if auth_error?(error)

    seconds = if rate_limit_error?(error)
      15.minutes.to_i
    elsif connection_error?(error)
      2.minutes.to_i
    else
      5.minutes.to_i
    end

    Time.current + [ seconds * (2**failure_count.to_i), 6.hours.to_i ].min
  end

  def rate_limit_error?(error)
    error.class.name.ends_with?("::RateLimitError")
  end

  def auth_error?(error)
    error.class.name.ends_with?("::AuthenticationError")
  end

  def connection_error?(error)
    error.class.name.ends_with?("::ConnectionError")
  end
end
