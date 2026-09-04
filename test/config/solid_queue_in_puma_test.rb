# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"

class SolidQueueInPumaTest < ActiveSupport::TestCase
  test "puma.rb starts the in-puma helper instead of the forking plugin" do
    source = Rails.root.join("config/puma.rb").read

    assert_includes source, "Shelfarr::SolidQueueInPuma"
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

  test "SOLID_QUEUE_IN_PUMA registers processes and performs SearchJob" do
    skip "Process.spawn is required for the in-puma supervisor probe" unless Process.respond_to?(:spawn)

    prefix = "sqip_#{SecureRandom.hex(4)}"
    env = probe_env(prefix)
    databases = probe_database_paths(prefix)

    command_env = probe_command_env(prefix)

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

  private

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
end
