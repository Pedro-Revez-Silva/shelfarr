class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :requests, dependent: :destroy
  has_many :uploads, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :activity_logs, dependent: :destroy

  scope :active, -> { where(deleted_at: nil) }

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
    if: -> { password.present? && !oidc_user? }

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

  # Soft delete
  def soft_delete!
    transaction do
      sessions.destroy_all
      update!(deleted_at: Time.current)
    end
  end

  def deleted?
    deleted_at.present?
  end

  # OIDC/SSO methods
  def oidc_user?
    oidc_uid.present? && oidc_provider.present?
  end

  # Find existing user or create new one from OIDC auth data
  def self.from_oidc(auth_hash)
    provider = auth_hash["provider"]
    uid = auth_hash["uid"]
    info = auth_hash["info"] || {}

    # First try to find by OIDC identity
    user = active.find_by(oidc_provider: provider, oidc_uid: uid)
    return user if user

    # Try to find by email and link the OIDC identity
    email = info["email"].to_s.strip.downcase
    if email.present?
      user = active.find_by(username: email.split("@").first.gsub(/[^a-z0-9_]/, "_"))
      if user && !user.oidc_user?
        user.update!(oidc_provider: provider, oidc_uid: uid)
        return user
      end
    end

    # Auto-create user if enabled
    return nil unless SettingsService.get(:oidc_auto_create_users, default: false)

    # Generate username from email or name
    base_username = if email.present?
      email.split("@").first.gsub(/[^a-z0-9_]/, "_").downcase
    else
      (info["name"] || info["preferred_username"] || "user").gsub(/[^a-z0-9_]/i, "_").downcase
    end

    # Ensure username is unique
    username = base_username
    counter = 1
    while exists?(username: username)
      username = "#{base_username}#{counter}"
      counter += 1
    end

    # Get name from OIDC claims
    name = info["name"].presence || info["preferred_username"].presence || username

    # Determine role
    default_role = SettingsService.get(:oidc_default_role, default: "user")
    role = default_role == "admin" ? :admin : :user

    # Create user with random password (they'll use OIDC to login)
    create!(
      username: username,
      name: name,
      password: SecureRandom.hex(32),
      role: role,
      oidc_provider: provider,
      oidc_uid: uid
    )
  end

  private

  def set_admin_if_first_user
    self.role = :admin if User.active.count.zero?
  end
end
