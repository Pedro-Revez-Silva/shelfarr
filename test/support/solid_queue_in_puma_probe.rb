# frozen_string_literal: true

# Isolated SOLID_QUEUE_IN_PUMA probe. A runner launches the real Puma server
# and verifies job execution and process lifecycle against separate databases.
#
# `rails runner` wraps this script in the Rails executor, which enables the
# Active Record query cache. Solid Queue writes happen in a child process, so
# counts and job lookups must be uncached or they stay stuck at the first miss.

require "json"
require "securerandom"
require "rbconfig"
require "net/http"
require "socket"
require "timeout"

ActiveJob::Base.queue_adapter = :solid_queue

def jobs_log_output
  path = ENV["SOLID_QUEUE_IN_PUMA_LOG"].to_s
  return "" if path.empty? || !File.exist?(path)

  File.read(path)
end

def wait_for(description, timeout: 30)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    result = yield
    return result if result
    raise "Timed out waiting for #{description}\n#{jobs_log_output}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end

def supervisors
  SolidQueue::Process.uncached { SolidQueue::Process.where(kind: "Supervisor").pluck(:pid) }
end

def process_exists?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

puma_log = "#{ENV.fetch('SOLID_QUEUE_IN_PUMA_LOG')}.puma"
worker_log = "#{puma_log}.workers"
mode = ENV.fetch("SQIP_MODE", "single")
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
server.close
puma_pid = nil
watchdog = Thread.new do
  sleep 240
  warn "Puma lifecycle probe exceeded 240 seconds (mode=#{mode})"
  warn File.read(puma_log) if File.exist?(puma_log)
  warn jobs_log_output
  Process.kill(:TERM, -puma_pid) rescue nil
  sleep 20
  Process.kill(:KILL, -puma_pid) rescue nil
  Process.kill(:KILL, Process.pid)
end
begin
  # Parallel Puma probes share tmp_restart's marker. Create it atomically
  # without touching an existing marker, so plugin startup cannot trigger a
  # restart in another probe through its check-then-write initialization.
  File.open(Rails.root.join("tmp/restart.txt"), File::WRONLY | File::CREAT, 0o644) { }
  # A stale PID must never suppress startup or be signalled at shutdown.
  File.write(ENV.fetch("SOLID_QUEUE_IN_PUMA_PIDFILE"), "#{Process.pid}\n")
  command = if mode == "single"
    [ RbConfig.ruby, "bin/rails", "server", "-b", "127.0.0.1", "-p", port.to_s ]
  else
    [ RbConfig.ruby, "-S", "puma", "-C", "test/support/solid_queue_puma_config.rb" ]
  end
  puma_pid = Process.spawn(
    { "PORT" => port.to_s, "PIDFILE" => "#{puma_log}.pid", "SQIP_WORKER_LOG" => worker_log,
      "WEB_CONCURRENCY" => mode == "single" ? "0" : "2", "COVERAGE" => nil, "PUMA_SKIP_SYSTEMD" => "1" },
    *command, out: [ puma_log, "a" ], err: [ :child, :out ], pgroup: true
  )
  puma_waiter = Process.detach(puma_pid)
  wait_for("Puma HTTP readiness") do
    raise "Puma exited: #{File.read(puma_log)}" unless puma_waiter.alive?
    begin
      Net::HTTP.start("127.0.0.1", port, open_timeout: 1, read_timeout: 1) { |http| http.get("/up").code == "200" }
    rescue SystemCallError, IOError, Timeout::Error
      false
    end
  end
  wait_for("one supervisor and a worker") do
    supervisors.one? && SolidQueue::Process.uncached { SolidQueue::Process.where(kind: "Worker").exists? }
  end
  supervisor_pid = supervisors.first
  process_count = SolidQueue::Process.uncached { SolidQueue::Process.count }
  started = true

  if mode != "single"
    wait_for("two web workers") { File.exist?(worker_log) && File.readlines(worker_log).length >= 2 }
    worker_pid = File.readlines(worker_log).first.to_i
    Process.kill(:TERM, worker_pid)
    # Puma allows 30 seconds to drain a worker, then checks/replaces workers
    # on a five-second interval. Give that lifecycle time to finish on CI.
    wait_for("replacement web worker", timeout: 60) { File.readlines(worker_log).length >= 3 }
    raise "Worker recycling stopped or duplicated the supervisor" unless supervisors == [ supervisor_pid ] && process_exists?(supervisor_pid)
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

  raise "SearchJob failed: #{result.inspect}" unless result[:search_job_finished] && !result[:request_still_pending]

  if mode == "single"
    Process.kill(:USR2, puma_pid)
    wait_for("replacement queue supervisor after hot restart") { supervisors.one? && supervisors.first != supervisor_pid }
    wait_for("old supervisor exit") { !process_exists?(supervisor_pid) }
    supervisor_pid = supervisors.first
    Process.kill(:TERM, puma_pid)
    raise "Puma did not stop" unless puma_waiter.join(25)
    wait_for("queue shutdown") { !process_exists?(supervisor_pid) }
  elsif mode == "cluster"
    Process.kill(:TERM, supervisor_pid)
    raise "Puma kept serving after queue exit" unless puma_waiter.join(25)
  else
    Process.kill(:KILL, puma_pid)
    puma_waiter.join(5)
    wait_for("orphaned queue supervisor shutdown") { supervisors.empty? }
  end
  result[:lifecycle_verified] = true
  puts JSON.generate(result)
ensure
  if puma_pid
    Process.kill(:TERM, -puma_pid) rescue nil
    puma_waiter&.join(20)
    Process.kill(:KILL, -puma_pid) rescue nil
  end
  # Print the server log on failure before the outer test removes probe files.
  warn File.read(puma_log) if $! && File.exist?(puma_log)
  FileUtils.rm_f([ puma_log, "#{puma_log}.pid", worker_log ])
  watchdog&.kill
end
