class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :requests, dependent: :destroy
  has_many :uploads, dependent: :destroy
  has_many :notifications, dependent: :destroy

  # Encrypt OTP secret and backup codes at rest
  encrypts :otp_secret
  encrypts :backup_codes

  enum :role, { user: 0, admin: 1 }, default: :user

  normalizes :username, with: ->(u) { u.strip.downcase }

  validates :username, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9_]+\z/, message: "only allows lowercase letters, numbers, and underscores" }
  validates :name, presence: true
  validates :password, length: { minimum: 12 },
    format: {
      with: /\A(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+\z/,
      message: "must include at least one lowercase letter, one uppercase letter, and one number"
    },
    if: -> { password.present? }

  before_create :set_admin_if_first_user

  # Check if the account is currently locked
  def locked?
    locked_until.present? && locked_until > Time.current
  end

  # Record a failed login attempt
  def record_failed_login!(ip_address)
    increment!(:failed_login_count)
    update!(
      last_failed_login_at: Time.current,
      last_failed_login_ip: ip_address
    )

    # Lock account if threshold exceeded
    threshold = SettingsService.get(:login_lockout_threshold, default: 5)
    if failed_login_count >= threshold
      lockout_minutes = SettingsService.get(:login_lockout_duration_minutes, default: 15)
      update!(locked_until: lockout_minutes.minutes.from_now)
      Rails.logger.warn "[Security] Account locked for user '#{username}' after #{failed_login_count} failed attempts from IP #{ip_address}"
    end
  end

  # Reset failed login count on successful login
  def reset_failed_logins!
    update!(
      failed_login_count: 0,
      locked_until: nil,
      last_failed_login_at: nil,
      last_failed_login_ip: nil
    )
  end

  # Time remaining until unlock
  def unlock_in_words
    return nil unless locked?

    distance = locked_until - Time.current
    if distance < 1.minute
      "#{distance.to_i} seconds"
    else
      "#{(distance / 60).ceil} minutes"
    end
  end

  # 2FA methods
  def otp_enabled?
    otp_required? && otp_secret.present?
  end

  def generate_otp_secret!
    update!(otp_secret: ROTP::Base32.random)
    otp_secret
  end

  def otp_provisioning_uri
    return nil unless otp_secret.present?

    totp = ROTP::TOTP.new(otp_secret, issuer: "Shelfarr")
    totp.provisioning_uri(username)
  end

  def verify_otp(code)
    return false unless otp_secret.present?

    totp = ROTP::TOTP.new(otp_secret)
    totp.verify(code, drift_behind: 30, drift_ahead: 30).present?
  end

  def enable_otp!
    codes = generate_backup_codes!
    update!(otp_required: true)
    codes
  end

  def disable_otp!
    update!(otp_required: false, otp_secret: nil, backup_codes: nil)
  end

  # Backup codes for 2FA recovery
  BACKUP_CODE_COUNT = 8

  def generate_backup_codes!
    codes = BACKUP_CODE_COUNT.times.map { SecureRandom.hex(4).upcase }
    # Store hashed codes
    hashed_codes = codes.map { |code| Digest::SHA256.hexdigest(code) }
    update!(backup_codes: hashed_codes.join(","))
    codes
  end

  def verify_backup_code(code)
    return false unless backup_codes.present?

    hashed_input = Digest::SHA256.hexdigest(code.to_s.upcase.gsub(/\s/, ""))
    remaining_codes = backup_codes.split(",")

    if remaining_codes.include?(hashed_input)
      # Remove used code (one-time use)
      remaining_codes.delete(hashed_input)
      update!(backup_codes: remaining_codes.any? ? remaining_codes.join(",") : nil)
      Rails.logger.info "[Security] Backup code used for user '#{username}'"
      true
    else
      false
    end
  end

  def backup_codes_remaining
    return 0 unless backup_codes.present?
    backup_codes.split(",").count
  end

  private

  def set_admin_if_first_user
    self.role = :admin if User.count.zero?
  end
end
