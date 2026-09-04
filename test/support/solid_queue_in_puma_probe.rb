# frozen_string_literal: true

# Isolated SOLID_QUEUE_IN_PUMA boot probe. Invoked via `bin/rails runner`.
# Prints a single JSON object describing supervisor registration and SearchJob.
#
# `rails runner` wraps this script in the Rails executor, which enables the
# Active Record query cache. Solid Queue writes happen in a child process, so
# counts and job lookups must be uncached or they stay stuck at the first miss.

require "json"
require "securerandom"

ActiveJob::Base.queue_adapter = :solid_queue

def jobs_log_output
  path = ENV["SOLID_QUEUE_IN_PUMA_LOG"].to_s
  return "" if path.empty? || !File.exist?(path)

  File.read(path)
end

begin
  started = Shelfarr::SolidQueueInPuma.start!(force: true)
  raise "failed to start Solid Queue supervisor" unless started || Shelfarr::SolidQueueInPuma.running?

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
  process_count = 0
  last_error = nil
  until process_count.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    ActiveRecord::Base.connection_handler.clear_all_connections!
    begin
      process_count = SolidQueue::Process.uncached { SolidQueue::Process.count }
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => e
      last_error = e
      process_count = 0
    end
    sleep 0.5
  end

  if process_count.zero?
    raise "solid_queue_processes stayed empty " \
      "(supervisor_alive=#{Shelfarr::SolidQueueInPuma.running?} " \
      "pid=#{Shelfarr::SolidQueueInPuma.current_pid} " \
      "last_error=#{last_error&.class}:#{last_error&.message})\n" \
      "bin/jobs output:\n#{jobs_log_output}"
  end

  user = User.create!(
    username: "sqip#{SecureRandom.hex(4)}",
    name: "Solid Queue Probe",
    password: "Password123!"
  )
  book = Book.create!(
    title: "Solid Queue Probe Book",
    author: "Probe Author",
    book_type: :ebook
  )
  request = Request.create!(
    book: book,
    user: user,
    status: :pending,
    created_via: "web",
    request_scope: "single"
  )

  job = SearchJob.perform_later(request.id)
  raise "SearchJob did not enqueue" unless job

  job_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
  solid_job = nil
  until Process.clock_gettime(Process::CLOCK_MONOTONIC) > job_deadline
    solid_job = SolidQueue::Job.uncached { SolidQueue::Job.find_by(active_job_id: job.job_id) }
    break if solid_job&.finished_at

    sleep 0.2
  end

  request.reload
  result = {
    started: started,
    process_count: SolidQueue::Process.uncached { SolidQueue::Process.count },
    process_kinds: SolidQueue::Process.uncached { SolidQueue::Process.distinct.pluck(:kind).sort },
    search_job_id: job.job_id,
    search_job_finished: solid_job&.finished_at.present?,
    request_status: request.status,
    request_still_pending: request.pending?
  }

  puts JSON.generate(result)
ensure
  Shelfarr::SolidQueueInPuma.stop!
end
