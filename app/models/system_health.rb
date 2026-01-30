class SystemHealth < ApplicationRecord
  enum :status, {
    healthy: 0,
    degraded: 1,
    down: 2,
    not_configured: 3
  }

  SERVICES = %w[prowlarr download_client output_paths audiobookshelf hardcover].freeze

  validates :service, presence: true, uniqueness: true
  validates :status, presence: true

  scope :unhealthy, -> { where(status: [:degraded, :down]) }

  def self.for_service(service_name)
    find_or_create_by(service: service_name) do |health|
      health.status = :healthy
    end
  end

  def healthy?
    status == "healthy"
  end

  def check_succeeded!(message: nil)
    update!(
      status: :healthy,
      message: message,
      last_check_at: Time.current,
      last_success_at: Time.current
    )
  end

  def check_failed!(message:, degraded: false)
    update!(
      status: degraded ? :degraded : :down,
      message: message,
      last_check_at: Time.current
    )
  end

  def mark_not_configured!(message: "Not configured")
    update!(
      status: :not_configured,
      message: message,
      last_check_at: Time.current
    )
  end
end
