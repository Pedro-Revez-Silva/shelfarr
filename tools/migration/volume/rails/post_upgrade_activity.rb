require "json"
require "securerandom"

plan = JSON.parse(ENV.fetch("M2_ACTIVITY"))
reader = User.find(plan.fetch("reader_id"))
token, raw = APIToken.issue!(name: "m2 consumer", user: reader, scopes: %w[library:read progress:write])
jobs = [ CleanupTempFilesJob.perform_later, UpdateCheckJob.set(wait: 2.days).perform_later ]
unknown = SolidQueue::Job.create!(queue_name: "vendor", class_name: "Vendor::NewlyAdmittedJob", arguments: { "job_class" => "Vendor::NewlyAdmittedJob", "arguments" => [ "M2-JOB-ARGUMENT-SENTINEL" ] }.to_json, active_job_id: SecureRandom.uuid, priority: 1)
puts "M2-RESULT #{JSON.generate("token_id" => token.id, "raw" => raw, "jobs" => jobs.map(&:provider_job_id), "unknown" => unknown.id)}"
