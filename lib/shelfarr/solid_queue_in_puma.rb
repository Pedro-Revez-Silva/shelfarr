# frozen_string_literal: true

require "fileutils"
require "pathname"

module Shelfarr
  # Puma starts a fresh supervisor after boot. Spawning bin/jobs avoids inheriting
  # Puma's threads and database connections, while keeping the two processes'
  # lifetimes coupled as in the upstream Solid Queue plugin.
  module SolidQueueInPuma
    SHUTDOWN_TIMEOUT = 15

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

        # Puma can run its shutdown hooks directly from a signal trap. Keep
        # the startup lock off the main thread so an interrupted startup can
        # finish and release it while shutdown waits for cleanup.
        Thread.new { start_supervisor(log_path) }.value
      end

      def stop!
        return false unless @owner_pid == Process.pid

        # Puma's cluster shutdown hook can run inside a signal trap, where
        # Ruby forbids Mutex#synchronize. Do cleanup on an ordinary thread.
        Thread.new { stop_supervisor }.value
      end

      def running?
        !!current_pid
      end

      def current_pid
        @pid if @owner_pid == Process.pid
      end

      # Called before Rails boot in bin/jobs. Remove the marker so separately
      # launched jobs cannot accidentally inherit this ownership relationship.
      def watch_parent!
        parent_pid = Integer(ENV.delete("SHELFARR_QUEUE_PARENT_PID").to_s, exception: false)
        return unless parent_pid && parent_pid.positive?

        Thread.new do
          sleep 0.5 while Process.ppid == parent_pid
          Process.kill(:INT, Process.pid)
          sleep SHUTDOWN_TIMEOUT
          target = Process.getpgrp == Process.pid ? -Process.pid : Process.pid
          Process.kill(:KILL, target)
        end
      end

      private

      def start_supervisor(log_path)
        @mutex ||= Mutex.new
        @mutex.synchronize do
          return false if current_pid

          @owner_pid = Process.pid
          @stopping = false
          @pidfile = pid_path
          FileUtils.mkdir_p(@pidfile.dirname)
          @pid = Process.spawn(
            { "SHELFARR_QUEUE_PARENT_PID" => @owner_pid.to_s },
            Gem.ruby, jobs_executable, spawn_options(log_path)
          )
          # This thread is the sole reaper. It also serializes reaping with
          # signaling to avoid racing our own cleanup.
          @reaper = Thread.new { monitor_supervisor }
          File.write(@pidfile, "#{@pid}\n")
          install_at_exit_hook!
          log("Started Solid Queue supervisor via bin/jobs (pid #{@pid})")
        rescue StandardError
          @stopping = true
          raise
        end
        true
      rescue StandardError
        stop!
        raise
      end

      def stop_supervisor
        reaper = @mutex.synchronize do
          @stopping = true
          signal_supervisor(:INT)
          @reaper
        end
        return false unless reaper

        unless reaper.join(SHUTDOWN_TIMEOUT)
          # Solid Queue normally stops its workers within its own timeout. Bound
          # Puma shutdown as well if the supervisor is stuck during boot/exit.
          @mutex.synchronize { signal_supervisor(:KILL) }
          reaper.join(1)
        end
        true
      end

      def monitor_supervisor
        loop do
          finished = @mutex.synchronize do
            begin
              exited = Process.waitpid(@pid, Process::WNOHANG)
            rescue Errno::ECHILD
              exited = @pid
            end
            if exited
              remove_pidfile(exited)
              @pid = nil
              unless @stopping
                log("Solid Queue supervisor exited; stopping Puma")
                Process.kill(:INT, @owner_pid)
              end
              true
            end
          end
          break if finished

          sleep 0.1
        end
      end

      def signal_supervisor(signal)
        return unless @pid

        # The supervisor owns a fresh process group. On forced shutdown, stop
        # its workers too; orphan detection can otherwise wait for a long poll.
        target = signal == :KILL ? -@pid : @pid
        Process.kill(signal, target)
      rescue Errno::ESRCH
        # The reaper will collect the exited child.
      end

      def remove_pidfile(pid)
        File.delete(@pidfile) if File.read(@pidfile).strip == pid.to_s
      rescue SystemCallError => error
        log("Could not remove supervisor pidfile: #{error.message}") unless error.is_a?(Errno::ENOENT)
      end

      def test_guard_blocks?(force)
        return false if force
        return false unless defined?(Rails) && Rails.env.test?

        ENV["SOLID_QUEUE_IN_PUMA_TEST"].to_s.empty?
      end

      def rails_root
        Pathname.new(File.expand_path("../..", __dir__))
      end

      def jobs_executable
        rails_root.join("bin/jobs").to_s
      end

      def spawn_options(log_path)
        options = { chdir: rails_root.to_s, close_others: true, pgroup: true }
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
        override = ENV["SOLID_QUEUE_IN_PUMA_PIDFILE"].to_s
        return Pathname.new(override) unless override.empty?

        rails_root.join("tmp/pids/solid_queue_in_puma.pid")
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
