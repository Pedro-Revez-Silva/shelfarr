# frozen_string_literal: true

# Isolated SOLID_QUEUE_IN_PUMA boot probe. Invoked via `bin/rails runner`.
# Prints a single JSON object describing supervisor registration and SearchJob.

require "json"
require "securerandom"

ActiveJob::Base.queue_adapter = :solid_queue

begin
  started = Shelfarr::SolidQueueInPuma.start!(force: true)
  raise "failed to start Solid Queue supervisor" unless started || Shelfarr::SolidQueueInPuma.running?

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  process_count = 0
  until process_count.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    process_count = SolidQueue::Process.count
    sleep 0.2
  end

  raise "solid_queue_processes stayed empty" if process_count.zero?

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
    solid_job = SolidQueue::Job.find_by(active_job_id: job.job_id)
    break if solid_job&.finished_at

    sleep 0.2
  end

  request.reload
  result = {
    started: started,
    process_count: SolidQueue::Process.count,
    process_kinds: SolidQueue::Process.distinct.pluck(:kind).sort,
    search_job_id: job.job_id,
    search_job_finished: solid_job&.finished_at.present?,
    request_status: request.status,
    request_still_pending: request.pending?
  }

  puts JSON.generate(result)
ensure
  Shelfarr::SolidQueueInPuma.stop!
end
