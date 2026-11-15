require "json"
require "securerandom"

plan = JSON.parse(ENV.fetch("M2_SEED"))
secret = -> { "#{SecureRandom.alphanumeric(18)}Aa1-" }
result = { "users" => {}, "plaintext_digests" => {}, "books" => {}, "tokens" => {}, "jobs" => {} }

plan.fetch("settings").each do |key, value|
  setting = Setting.find_by(key: key)
  setting ? setting.update!(value: value) : Setting.create!(key: key, value: value, value_type: "string", category: "general")
end

{ "admin" => [ :admin, {} ], "reader" => [ :user, {} ], "otp" => [ :user, { otp_required: true } ], "gone" => [ :user, {} ] }.each do |label, (role, extra)|
  password = secret.call
  user = User.create!({ username: "m2_#{label}", name: "M2 #{label}", password: password, role: role }.merge(extra))
  result["users"][label] = { "id" => user.id, "password" => password }
end
otp = User.find(result["users"]["otp"]["id"])
otp_secret = "#{SecureRandom.alphanumeric(26).upcase}"
backup = [ SecureRandom.hex(5), SecureRandom.hex(5) ].to_json
otp.update!(otp_secret: otp_secret, backup_codes: backup)
result["plaintext_digests"]["otp_secret"] = Digest::SHA256.hexdigest(otp_secret)
result["plaintext_digests"]["backup_codes"] = Digest::SHA256.hexdigest(backup)
User.find(result["users"]["gone"]["id"]).update_columns(deleted_at: Time.current)

clients = {
  "sab" => DownloadClient.create!(name: "m2 sab", client_type: :sabnzbd, url: "http://127.0.0.1:9", api_key: SecureRandom.hex(16)),
  "deluge" => DownloadClient.create!(name: "m2 deluge", client_type: :deluge, url: "http://127.0.0.1:9", username: "m2", password: secret.call)
}
result["plaintext_digests"]["download_client_api_key"] = Digest::SHA256.hexdigest(clients["sab"].api_key)
result["plaintext_digests"]["download_client_password"] = Digest::SHA256.hexdigest(clients["deluge"].password)

admin = User.find(result["users"]["admin"]["id"])
reader = User.find(result["users"]["reader"]["id"])

plan.fetch("books").each do |label, spec|
  attributes = { title: spec.fetch("title"), author: spec.fetch("author"), book_type: spec.fetch("type"), file_path: spec["file_path"] }
  attributes[:reference_target_roots] = spec["reference_target_roots"].map { |path| { "path" => path, "device" => File.stat(path).dev, "inode" => File.stat(path).ino } } if spec["reference_target_roots"]
  book = Book.create!(attributes)
  result["books"][label] = book.id
  next unless spec["request"]

  request = Request.create!(book: book, user: reader, status: spec.fetch("request"), created_via: "web", request_scope: "single")
  Download.create!(request: request, status: :completed, name: spec.fetch("title"), progress: 100, size_bytes: 1024, download_client: clients["sab"]) if spec["request"] == "completed"
end

legacy, raw = APIToken.issue!(name: "m2 legacy", user: admin, scopes: %w[search:read requests:read requests:write])
result["tokens"]["legacy_admin"] = { "id" => legacy.id, "raw" => raw }
revoked, _ = APIToken.issue!(name: "m2 revoked", user: reader, scopes: %w[search:read])
revoked.update!(revoked_at: Time.current)

cleanup = CleanupTempFilesJob.perform_later
later = CleanupTempFilesJob.set(wait: 1.day).perform_later
failed_job = SolidQueue::Job.create!(queue_name: "default", class_name: "CleanupTempFilesJob", arguments: { "job_class" => "CleanupTempFilesJob", "arguments" => [], "m2" => "failed" }.to_json, active_job_id: SecureRandom.uuid, priority: 0)
SolidQueue::ReadyExecution.where(job_id: failed_job.id).delete_all
SolidQueue::FailedExecution.create!(job_id: failed_job.id, error: "synthetic failure")
unknown = SolidQueue::Job.create!(queue_name: "vendor", class_name: "Vendor::UnportedJob", arguments: { "job_class" => "Vendor::UnportedJob", "arguments" => [ "M2-JOB-ARGUMENT-SENTINEL" ] }.to_json, active_job_id: SecureRandom.uuid, priority: 3)
result["jobs"] = { "ready" => cleanup.provider_job_id, "scheduled" => later.provider_job_id, "failed" => failed_job.id, "unknown" => unknown.id }

ActionCable.server.broadcast("m2-synthetic", { "kind" => "synthetic" })
Rails.cache.write("m2-synthetic", "value")

result["counts"] = { "users" => User.count, "books" => Book.count, "requests" => Request.count, "settings" => Setting.count }
puts "M2-RESULT #{JSON.generate(result)}"
