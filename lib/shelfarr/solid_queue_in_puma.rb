# frozen_string_literal: true

require "fileutils"
require "pathname"

module Shelfarr
  # Starts Solid Queue for single-container deploys that set SOLID_QUEUE_IN_PUMA.
  #
  # The upstream Puma plugin forks the supervisor from `after_booted`, after
  # Rails has eager-loaded and Puma's thread pool is already running. Forking
  # that process can hang before `solid_queue_processes` is written, so jobs
  # stay enqueued forever. A fresh `bin/jobs` process avoids inheriting those
  # threads and SQLite handles.
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

      def start!(force: false, log_path: nil)
        return false unless enabled?
        return false if test_guard_blocks?(force)
        return false if !force && !server_process?
        return false if running?

        FileUtils.mkdir_p(pid_path.dirname)
        disconnect_connections!

        pid = Process.spawn(Gem.ruby, jobs_executable, spawn_options(log_path))
        @pid = pid
        File.write(pid_path, "#{pid}\n")
        install_at_exit_hook!

        if supervisor_exited_immediately?(pid)
          log("Solid Queue supervisor exited immediately (pid #{pid})")
          @pid = nil
          File.delete(pid_path) if File.exist?(pid_path)
          return false
        end

        log("Started Solid Queue supervisor via bin/jobs (pid #{pid})")
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
        !Process.waitpid(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD, Errno::ESRCH
        true
      end

      def rails_root
        defined?(Rails) ? Rails.root : Pathname.new(File.expand_path("../..", __dir__))
      end

      def jobs_executable
        rails_root.join("bin/jobs").to_s
      end

      def spawn_options(log_path)
        options = {
          chdir: rails_root.to_s,
          close_others: true
        }

        resolved_log = log_path.to_s
        resolved_log = ENV.fetch("SOLID_QUEUE_IN_PUMA_LOG", "") if resolved_log.empty?

        if resolved_log.empty?
          options[:out] = $stdout
          options[:err] = $stderr
        else
          FileUtils.mkdir_p(File.dirname(resolved_log))
          options[:out] = [ resolved_log, "a" ]
          options[:err] = [ :child, :out ]
        end

        options
      end

      def pid_path
        if (override = ENV["SOLID_QUEUE_IN_PUMA_PIDFILE"].to_s) && !override.empty?
          return Pathname.new(override)
        end

        rails_root.join("tmp/pids/solid_queue_in_puma.pid")
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
