# frozen_string_literal: true

module OfflineContinuity
  PREFIX = "shelfarr_offline_"
  LIFETIME = 400.days

  def self.cookie_name(mount)
    "#{PREFIX}#{Digest::SHA256.hexdigest(mount).first(16)}"
  end

  private

  def rotate_offline_continuity
    write_offline_continuity(SecureRandom.alphanumeric(24))
  end

  def offline_continuity
    cookies[offline_continuity_cookie].presence || rotate_offline_continuity
  end

  def offline_continuity_cookie
    OfflineContinuity.cookie_name(web_preview_path)
  end

  def write_offline_continuity(value)
    cookies[offline_continuity_cookie] = { value: value, path: web_preview_path, expires: LIFETIME.from_now,
      same_site: :lax, secure: request.ssl?, httponly: false }
    value
  end
end
