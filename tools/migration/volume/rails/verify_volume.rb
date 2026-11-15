require "json"
require "digest"

expect = JSON.parse(ENV.fetch("M2_EXPECT"))
digest = ->(value) { Digest::SHA256.hexdigest(value.to_s) }
otp = User.find(expect.fetch("otp_user_id"))
sab = DownloadClient.find_by!(name: "m2 sab")
deluge = DownloadClient.find_by!(name: "m2 deluge")
outcome = {
  "otp_secret" => digest.call(otp.otp_secret) == expect.fetch("otp_secret"),
  "backup_codes" => digest.call(otp.backup_codes) == expect.fetch("backup_codes"),
  "api_key" => digest.call(sab.api_key) == expect.fetch("download_client_api_key"),
  "password" => digest.call(deluge.password) == expect.fetch("download_client_password"),
  "password_authenticates" => User.find(expect.fetch("reader_id")).authenticate(expect.fetch("reader_password")) ? true : false,
  "books" => Book.count,
  "users" => User.count,
  "jobs" => SolidQueue::Job.count,
  "schema" => ActiveRecord::Base.connection_pool.migration_context.current_version
}
puts "M2-RESULT #{JSON.generate(outcome)}"
