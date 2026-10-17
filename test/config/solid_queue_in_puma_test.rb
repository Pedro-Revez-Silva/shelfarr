# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "timeout"
require "tmpdir"

class SolidQueueInPumaTest < ActiveSupport::TestCase
  test "puma.rb starts the in-puma helper instead of the forking plugin" do
    source = Rails.root.join("config/puma.rb").read

    assert_includes source, "Shelfarr::SolidQueueInPuma"
    assert_includes source, "force_shutdown_after 30"
    refute_match(/^\s*plugin\s+:solid_queue\b/, source)
  end

  test "helper is disabled when SOLID_QUEUE_IN_PUMA is unset" do
    with_env("SOLID_QUEUE_IN_PUMA" => nil) do
      refute Shelfarr::SolidQueueInPuma.enabled?
      refute Shelfarr::SolidQueueInPuma.start!
    end
  end

  test "runner processes are not treated as the web server" do
    refute Shelfarr::SolidQueueInPuma.server_process?
  end

  test "puma executable is treated as a server process" do
    original = $PROGRAM_NAME
    $PROGRAM_NAME = "/usr/local/bundle/bin/puma"

    assert Shelfarr::SolidQueueInPuma.server_process?
  ensure
    $PROGRAM_NAME = original
  end

  test "Rails::Server is treated as a server process" do
    skip if defined?(Rails::Server)

    Rails.const_set(:Server, Class.new)
    begin
      assert Shelfarr::SolidQueueInPuma.server_process?
    ensure
      Rails.send(:remove_const, :Server)
    end
  end

  test "probe command env unsets COVERAGE so child rails processes skip SimpleCov" do
    with_env("COVERAGE" => "1") do
      env = probe_command_env("sqip_example")

      assert env.key?("COVERAGE")
      assert_nil env["COVERAGE"]
    end
  end

  test "helper starts a fresh bin/jobs process instead of forking the supervisor" do
    source = Rails.root.join("lib/shelfarr/solid_queue_in_puma.rb").read

    assert_includes source, "Process.spawn"
    assert_includes source, "jobs_executable"
    refute_includes source, "SolidQueue::Supervisor.start"
  end

  test "shutdown during supervisor spawn does not deadlock" do
    Dir.mktmpdir("sqip-signal-trap") do |directory|
      pidfile = File.join(directory, "supervisor.pid")
      script = <<~'RUBY'
        require "rbconfig"
        require "shelfarr/solid_queue_in_puma"

        # Noninteractive parents may pass an ignored INT to a fresh child.
        trap(:INT, "IGNORE")

        class << Process
          alias_method :sqip_real_spawn, :spawn

          def spawn(*)
            Thread.new do
              sleep 0.05
              Process.kill(:USR1, Process.pid)
            end
            sleep 0.25
            ready_reader, ready_writer = IO.pipe
            supervisor_script = <<~'SUPERVISOR'
              trap(:INT) { exit }
              ready = IO.for_fd(3)
              ready.puts("ready")
              ready.close
              sleep 10
            SUPERVISOR
            pid = sqip_real_spawn(
              RbConfig.ruby,
              "-e",
              supervisor_script,
              3 => ready_writer,
              pgroup: true,
              out: File::NULL,
              err: File::NULL
            )
            ready_writer.close
            # Keep the spawn lock held until the child can handle shutdown.
            ready = IO.select([ready_reader], nil, nil, 3) && ready_reader.gets == "ready\n"
            raise "supervisor did not become ready" unless ready
            pid
          rescue StandardError
            if pid
              begin
                Process.kill(:KILL, -pid)
              rescue Errno::ESRCH
              end
              begin
                Process.waitpid(pid)
              rescue Errno::ECHILD
              end
            end
            raise
          ensure
            ready_reader&.close
            ready_writer&.close unless ready_writer&.closed?
          end
        end

        trap(:USR1) { Shelfarr::SolidQueueInPuma.stop! }
        Shelfarr::SolidQueueInPuma.start!(force: true)
      RUBY

      stdout, stderr, status, timed_out = capture_signal_trap_probe(
        {
          "SOLID_QUEUE_IN_PUMA" => "1",
          "SOLID_QUEUE_IN_PUMA_PIDFILE" => pidfile
        },
        script
      )

      refute timed_out, "shutdown deadlocked during supervisor spawn"
      assert status.success?, [ stdout, stderr ].reject(&:empty?).join("\n")
    end
  end

  %w[single cluster cluster_preload].each do |mode|
    test "SOLID_QUEUE_IN_PUMA boots Puma and handles #{mode} lifecycle" do
      run_puma_probe(mode)
    end
  end

  test "stop ignores a supervisor owned by another process" do
    with_queue_runtime do |helper|
      helper.instance_variable_set(:@owner_pid, Process.pid + 1)

      assert_equal false, helper.stop!
    end
  end

  test "stop outside a trap signals the supervisor without joining from a handler" do
    with_queue_runtime do |helper|
      helper.instance_variable_set(:@owner_pid, Process.pid)
      helper.instance_variable_set(:@mutex, Mutex.new)
      helper.instance_variable_set(:@pid, nil)
      helper.instance_variable_set(:@reaper, nil)

      assert_equal false, helper.stop!
      assert helper.instance_variable_get(:@stopping)
    end
  end

  test "stop inside a trap interrupts the supervisor without taking the mutex" do
    child = spawn_ruby("trap(:INT) { exit }; sleep 30", pgroup: true)
    with_queue_runtime do |helper|
      helper.instance_variable_set(:@owner_pid, Process.pid)
      helper.instance_variable_set(:@pid, child)
      helper.remove_instance_variable(:@mutex) if helper.instance_variable_defined?(:@mutex)

      result = nil
      error = nil
      previous = trap(:USR1) do
        result = helper.stop!
      rescue StandardError => caught
        error = caught
      end
      Process.kill(:USR1, Process.pid)

      assert_nil error
      assert_equal true, result
      assert helper.instance_variable_get(:@stopping)
    ensure
      trap(:USR1, previous || "DEFAULT")
    end
  ensure
    reap_process(child, group: true)
  end

  test "trap stop gives up when the supervisor pid never appears" do
    with_queue_runtime do |helper|
      helper.instance_variable_set(:@pid, nil)
      clocks = [ 0.0, 0.0, 5.0 ]

      Process.stub(:clock_gettime, ->(*) { clocks.shift || 5.0 }) do
        assert_equal true, helper.send(:stop_from_trap)
      end
      assert helper.instance_variable_get(:@stopping)
    end
  end

  test "trap stop kills a supervisor that ignores INT" do
    child = spawn_ruby("trap(:INT, 'IGNORE'); sleep 30", pgroup: true)
    with_queue_runtime do |helper|
      helper.instance_variable_set(:@pid, child)

      helper.stub(:wait_pid, false) do
        assert_equal true, helper.send(:stop_from_trap)
      end
    end
  ensure
    reap_process(child, group: true)
  end

  test "wait_pid reports a reaped child and times out on one that stays up" do
    sleeper = spawn_ruby("sleep 30")
    with_queue_runtime do |helper|
      assert_equal true, helper.send(:wait_pid, Process.pid, 0.2)
      assert_equal false, helper.send(:wait_pid, sleeper, 0.02)
      assert_nil helper.send(:signal_pid, unused_pid, :INT)
    end
  ensure
    reap_process(sleeper)
  end

  test "reaper stops puma when the supervisor exits on its own" do
    child = spawn_ruby("exit")
    owner = spawn_ruby("trap(:INT) { exit }; sleep 30")
    wait_until_zombie(child)
    with_queue_runtime do |helper|
      Dir.mktmpdir("sqip-reaper") do |directory|
        pidfile = write_pidfile(directory, child)
        assign_reaper_state(helper, pid: child, owner: owner, pidfile: pidfile, stopping: false)

        helper.send(:monitor_supervisor)

        assert_nil helper.instance_variable_get(:@pid)
        refute_path_exists pidfile
      end
    end
    assert_process_exited(owner)
  ensure
    reap_process(child)
    reap_process(owner)
  end

  test "reaper does not signal puma for an exit it already requested" do
    child = spawn_ruby("exit")
    wait_until_zombie(child)
    with_queue_runtime do |helper|
      Dir.mktmpdir("sqip-reaper-stopping") do |directory|
        assign_reaper_state(helper, pid: child, owner: Process.pid, pidfile: write_pidfile(directory, child), stopping: true)

        helper.send(:monitor_supervisor)

        assert Process.kill(0, Process.pid)
      end
    end
  ensure
    reap_process(child)
  end

  test "reaper treats a vanished supervisor as already gone" do
    missing = unused_pid
    with_queue_runtime do |helper|
      Dir.mktmpdir("sqip-reaper-missing") do |directory|
        assign_reaper_state(helper, pid: missing, owner: missing, pidfile: write_pidfile(directory, missing), stopping: false)

        assert_nil helper.send(:monitor_supervisor)
      end
    end
  end

  test "reaper waits while the supervisor is still running" do
    child = spawn_ruby("sleep 0.3")
    with_queue_runtime do |helper|
      Dir.mktmpdir("sqip-reaper-wait") do |directory|
        assign_reaper_state(helper, pid: child, owner: Process.pid, pidfile: write_pidfile(directory, child), stopping: true)

        helper.send(:monitor_supervisor)

        assert_nil helper.instance_variable_get(:@pid)
      end
    end
  ensure
    reap_process(child)
  end

  private

  def run_puma_probe(mode)
    skip "Process.spawn is required for the in-puma supervisor probe" unless Process.respond_to?(:spawn)

    prefix = "sqip_#{SecureRandom.hex(4)}"
    env = probe_env(prefix)
    databases = probe_database_paths(prefix)

    command_env = probe_command_env(prefix).merge("SQIP_MODE" => mode)

    prepare_output, prepare_status = Open3.capture2e(
      command_env,
      RbConfig.ruby,
      "bin/rails",
      "db:prepare",
      chdir: Rails.root.to_s
    )
    assert prepare_status.success?, prepare_output

    output, error, status = Open3.capture3(
      command_env,
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "--skip-executor",
      "test/support/solid_queue_in_puma_probe.rb",
      chdir: Rails.root.to_s
    )

    jobs_output = File.exist?(env["SOLID_QUEUE_IN_PUMA_LOG"]) ? File.read(env["SOLID_QUEUE_IN_PUMA_LOG"]) : ""
    assert status.success?, [ error, output, jobs_output ].reject(&:empty?).join("\n")

    result = JSON.parse(output.lines.last)
    assert result.fetch("lifecycle_verified")
    assert result.fetch("process_count") > 0, "expected solid_queue_processes to register, got #{result.inspect}"
    kinds = result.fetch("process_kinds").map { |kind| kind.to_s.downcase }
    assert kinds.any? { |kind| kind.include?("supervisor") || kind.include?("worker") },
      "expected a supervisor or worker process, got #{result.inspect}"
    assert result.fetch("search_job_finished"), "SearchJob stayed enqueued: #{result.inspect}"
    refute result.fetch("request_still_pending"), "SearchJob never left pending: #{result.inspect}"
  ensure
    databases&.each { |path| FileUtils.rm_f(path) }
    if env
      FileUtils.rm_f(env["SOLID_QUEUE_IN_PUMA_PIDFILE"])
      FileUtils.rm_f(env["SOLID_QUEUE_IN_PUMA_LOG"])
    end
  end

  def probe_env(prefix)
    {
      "RAILS_ENV" => "test",
      "SOLID_QUEUE_IN_PUMA" => "1",
      "SOLID_QUEUE_IN_PUMA_TEST" => "1",
      "SHELFARR_TEST_DB" => "#{prefix}_primary",
      "SHELFARR_TEST_QUEUE_DB" => "#{prefix}_queue",
      "SHELFARR_TEST_CABLE_DB" => "#{prefix}_cable",
      "SOLID_QUEUE_IN_PUMA_PIDFILE" => Rails.root.join("tmp/pids/#{prefix}.pid").to_s,
      "SOLID_QUEUE_IN_PUMA_LOG" => Rails.root.join("tmp/#{prefix}-jobs.log").to_s
    }
  end

  def probe_command_env(prefix)
    # Open3/Process.spawn env hashes update the parent environment. Deleting a
    # key leaves the parent's value in place; nil unsets it. Quality's coverage
    # pass sets COVERAGE=1, which would otherwise start SimpleCov in db:prepare
    # and fail the child on the global coverage floor.
    ENV.to_h.merge(probe_env(prefix)).merge("COVERAGE" => nil)
  end

  def probe_database_paths(prefix)
    %W[
      storage/#{prefix}_primary.sqlite3
      storage/#{prefix}_primary.sqlite3-wal
      storage/#{prefix}_primary.sqlite3-shm
      storage/#{prefix}_queue.sqlite3
      storage/#{prefix}_queue.sqlite3-wal
      storage/#{prefix}_queue.sqlite3-shm
      storage/#{prefix}_cable.sqlite3
      storage/#{prefix}_cable.sqlite3-wal
      storage/#{prefix}_cable.sqlite3-shm
    ].map { |relative| Rails.root.join(relative) }
  end

  def with_queue_runtime
    helper = Shelfarr::SolidQueueInPuma
    saved = helper.instance_variables.to_h { |name| [ name, helper.instance_variable_get(name) ] }
    yield helper
  ensure
    helper.instance_variables.each do |name|
      helper.remove_instance_variable(name)
    end
    saved&.each do |name, value|
      helper.instance_variable_set(name, value)
    end
  end

  def assign_reaper_state(helper, pid:, owner:, pidfile:, stopping:)
    helper.instance_variable_set(:@mutex, Mutex.new)
    helper.instance_variable_set(:@pid, pid)
    helper.instance_variable_set(:@owner_pid, owner)
    helper.instance_variable_set(:@pidfile, pidfile)
    helper.instance_variable_set(:@stopping, stopping)
  end

  def write_pidfile(directory, pid)
    path = File.join(directory, "supervisor.pid")
    File.write(path, "#{pid}\n")
    Pathname.new(path)
  end

  def spawn_ruby(script, pgroup: false)
    Process.spawn(RbConfig.ruby, "-e", script, pgroup: pgroup, out: File::NULL, err: File::NULL)
  end

  def unused_pid
    candidate = 1 << 22
    candidate += 1 while process_alive?(candidate)
    candidate
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def wait_until_zombie(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      state = File.read("/proc/#{pid}/stat").split[2]
      return if state == "Z"
      raise "supervisor #{pid} exited before the reaper could observe it" unless process_alive?(pid)
      raise "supervisor #{pid} did not become a zombie" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def assert_process_exited(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      reaped = Process.waitpid(pid, Process::WNOHANG)
      return if reaped
      raise "pid #{pid} stayed alive" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  rescue Errno::ECHILD
    nil
  end

  def reap_process(pid, group: false)
    return unless pid

    signal = group ? -pid : pid
    Process.kill(:KILL, signal)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  ensure
    begin
      Process.waitpid(pid) if pid
    rescue Errno::ECHILD
      nil
    end
  end

  def capture_signal_trap_probe(env, script)
    stdout = stderr = ""
    status = nil
    timed_out = false

    Open3.popen3(
      env,
      RbConfig.ruby,
      "-I#{Rails.root.join('lib')}",
      "-e",
      script,
      chdir: Rails.root.to_s
    ) do |stdin, out, err, waiter|
      stdin.close
      stdout_reader = Thread.new { out.read }
      stderr_reader = Thread.new { err.read }

      begin
        status = Timeout.timeout(5) { waiter.value }
      rescue Timeout::Error
        timed_out = true
        Process.kill(:KILL, waiter.pid)
        status = waiter.value
      ensure
        stdout = stdout_reader.value
        stderr = stderr_reader.value
      end
    end

    [ stdout, stderr, status, timed_out ]
  end
end
