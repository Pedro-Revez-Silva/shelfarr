threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

plugin :tmp_restart

# Default is to wait forever for in-flight requests. A thread that never
# returns then pins hot restart and SIGTERM, so the master stays alive after
# the queue supervisor has been told to exit. Bound the drain; Puma still
# gives threads a short grace period before killing them.
force_shutdown_after 30

# Start Solid Queue once in the Puma master, after worker forks.
# Do not use `plugin :solid_queue` here: that plugin forks after Puma's thread
# pool is already running, which can leave solid_queue_processes empty and
# SearchJob stuck enqueued (see Shelfarr::SolidQueueInPuma).
if ENV["SOLID_QUEUE_IN_PUMA"]
  start_solid_queue = lambda do
    require_relative "../lib/shelfarr/solid_queue_in_puma"
    Shelfarr::SolidQueueInPuma.start!(force: true)
  end
  stop_solid_queue = lambda do |_launcher = nil|
    require_relative "../lib/shelfarr/solid_queue_in_puma"
    Shelfarr::SolidQueueInPuma.stop!
  end

  if respond_to?(:after_booted)
    after_booted(&start_solid_queue)
    after_stopped(&stop_solid_queue)
    before_restart(&stop_solid_queue) if respond_to?(:before_restart)
  else
    on_booted(&start_solid_queue)
    on_stopped(&stop_solid_queue)
    on_restart(&stop_solid_queue)
  end
end

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
