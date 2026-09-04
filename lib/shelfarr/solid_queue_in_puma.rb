# frozen_string_literal: true

require "fileutils"
require "pathname"

module Shelfarr
  # Starts Solid Queue for single-container deploys that set SOLID_QUEUE_IN_PUMA.
  #
  # The upstream Puma plugin forks the supervisor from `after_booted`, after
  # Puma's thread pool is already running and after boot-time code may have
  # opened the SQLite queue database. That fork can die or deadlock before
  # `solid_queue_processes` is written, so jobs stay enqueued forever.
  #
  # This helper forks from Rails server boot (before Puma becomes multi-threaded)
  # and disconnects Active Record first so the supervisor child does not inherit
  # live SQLite handles.
  module SolidQueueInPuma
    class << self
      def enabled?
        !ENV["SOLID_QUEUE_IN_PUMA"].to_s.empty?
      end

      def server_process?
        return true if defined?(::Rails::Server)

        program = File.basename($PROGRAM_NAME.to_s).downcase
        program == "puma" || program.end_with?("-puma")
      end

      def start!(force: false)
        return false unless enabled?
        return false if test_guard_blocks?(force)
        return false if !force && !server_process?
        return false if running?
        unless Process.respond_to?(:fork)
          log("SOLID_QUEUE_IN_PUMA requires Process.fork")
          return false
        end

        FileUtils.mkdir_p(pid_path.dirname)
        disconnect_connections!

        pid = fork do
          disconnect_connections!
          SolidQueue::Supervisor.start
        end

        @pid = pid
        File.write(pid_path, "#{pid}\n")
        install_at_exit_hook!

        if supervisor_exited_immediately?(pid)
          log("Solid Queue supervisor exited immediately (pid #{pid})")
          @pid = nil
          File.delete(pid_path) if File.exist?(pid_path)
          return false
        end

        log("Started Solid Queue supervisor (pid #{pid})")
        true
      end

      def stop!
        pid = current_pid
        return false unless pid

        if process_alive?(pid)
          Process.kill(:INT, pid)
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            # Reaped elsewhere
          end
        end

        true
      ensure
        @pid = nil
        File.delete(pid_path) if File.exist?(pid_path)
      end

      def running?
        pid = current_pid
        pid && process_alive?(pid)
      end

      def current_pid
        @pid || read_pidfile
      end

      private

      def test_guard_blocks?(force)
        return false if force
        return false unless defined?(Rails) && Rails.env.test?

        ENV["SOLID_QUEUE_IN_PUMA_TEST"].to_s.empty?
      end

      def supervisor_exited_immediately?(pid)
        exited = Process.waitpid(pid, Process::WNOHANG)
        !exited.nil?
      rescue Errno::ECHILD, Errno::ESRCH
        true
      end

      def pid_path
        if (override = ENV["SOLID_QUEUE_IN_PUMA_PIDFILE"].to_s) && !override.empty?
          return Pathname.new(override)
        end

        root = defined?(Rails) ? Rails.root : Pathname.new(File.expand_path("../..", __dir__))
        root.join("tmp/pids/solid_queue_in_puma.pid")
      end

      def read_pidfile
        return unless File.exist?(pid_path)

        Integer(File.read(pid_path).to_s.strip, exception: false)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def disconnect_connections!
        return unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.connection_handler.clear_all_connections!
      rescue StandardError
        nil
      end

      def install_at_exit_hook!
        return if @at_exit_installed

        @at_exit_installed = true
        at_exit { stop! }
      end

      def log(message)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.info("[Shelfarr] #{message}")
        else
          warn("[Shelfarr] #{message}")
        end
      end
    end
  end
end
