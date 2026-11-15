# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "command"
require_relative "pins"

module Migration
  module Volume
    class Docker
      LABEL = "org.shelfarr.m2.project"
      HELPER_IMAGE = Pins::RUBY_IMAGE
      EXEC_PREAMBLE = <<~SH
        [ -n "$SECRET_KEY_BASE" ] || { [ -f /rails/storage/.secret_key_base ] && export SECRET_KEY_BASE="$(cat /rails/storage/.secret_key_base)"; }
        [ -n "$ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" ] || { [ -f /rails/storage/.encryption_keys ] && . /rails/storage/.encryption_keys; }
      SH

      attr_reader :project

      def initialize(project: "#{Pins::PROJECT_PREFIX}-#{SecureRandom.hex(4)}")
        @project = project
        @containers = []
      end

      def name(role) = "#{@project}-#{role}"

      def start(image:, role:, storage:, media: {}, environment: {}, entrypoint: nil, command: [], interactive: false, cpus: nil)
        container = name(role)
        arguments = [ "docker", "run", "--detach", "--name", container, "--label", "#{LABEL}=#{@project}", "--network", "none",
                      "--memory", "2g", "--pids-limit", "512", "--volume", "#{storage}:/rails/storage" ]
        media.each { |target, source| arguments.push("--volume", "#{source}:#{target}") }
        environment.each { |key, value| arguments.push("--env", "#{key}=#{value}") }
        arguments.push("--cpus", cpus.to_s) if cpus
        arguments.push("--entrypoint", entrypoint) if entrypoint
        arguments.push("--interactive") if interactive
        arguments.push(image, *command)
        Command.run!(*arguments)
        @containers << container
        container
      end

      def wait_ready(container, timeout: 240)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if http(container, "GET", "/up").first == 200
          raise CommandFailed, "#{container} exited before it became ready (#{exit_code(container)})" unless running?(container)
          raise CommandTimedOut, "#{container} not ready within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 1
        end
      end

      def running?(container)
        Command.capture("docker", "inspect", "--format", "{{.State.Running}}", container).output.strip == "true"
      end

      def exit_code(container)
        Command.capture("docker", "inspect", "--format", "{{.State.ExitCode}}", container).output.strip.to_i
      end

      def wait_exit(container, timeout: 600)
        output = Command.run!("docker", "wait", container, timeout: timeout)
        output.strip.to_i
      end

      def stop(container, grace: 30)
        Command.capture("docker", "stop", "--time", grace.to_s, container, timeout: grace + 30)
      end

      def kill(container)
        Command.capture("docker", "kill", container)
      end

      def remove(container)
        Command.capture("docker", "rm", "--force", container)
        @containers.delete(container)
      end

      def logs(container, lines: nil)
        arguments = [ "docker", "logs" ]
        arguments.push("--tail", lines.to_s) if lines
        Command.capture(*arguments, container).then { |result| result.output + result.error }
      end

      def logged?(container, text)
        logs(container).include?(text)
      end

      Response = Data.define(:status, :headers, :body) do
        def cookie(name)
          Array(headers["set-cookie"]).filter_map { |line| line[/\A#{Regexp.escape(name)}=([^;]*)/, 1] }.last
        end
      end

      def request(container, verb, path, headers: {}, body: nil, cookie: nil)
        arguments = [ "docker", "exec", "--interactive", container, "curl", "--silent", "--show-error", "--include", "--max-time", "30", "--request", verb ]
        headers.each { |key, value| arguments.push("--header", "#{key}: #{value}") }
        arguments.push("--header", "Cookie: #{cookie}") if cookie
        arguments.push("--data-binary", "@-") if body
        arguments.push("http://127.0.0.1:80#{path}")
        result = Command.capture(*arguments, stdin: body, timeout: 45)
        return Response.new(status: 0, headers: {}, body: "") unless result.success?

        head, _, payload = result.output.partition("\r\n\r\n")
        lines = head.split("\r\n")
        table = lines.drop(1).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, memo|
          name, value = line.split(": ", 2)
          memo[name.downcase] << value.to_s
        end
        Response.new(status: lines.first.to_s[/\s(\d{3})\s/, 1].to_i, headers: table, body: payload)
      end

      def http(container, verb, path, **options)
        response = request(container, verb, path, **options)
        [ response.status, response.body ]
      end

      def rails_runner(container, source, environment: {}, timeout: 300)
        arguments = [ "docker", "exec", "--interactive" ]
        environment.each { |key, value| arguments.push("--env", "#{key}=#{value}") }
        arguments.push(container, "sh", "-c", "#{EXEC_PREAMBLE}exec gosu rails ./bin/rails runner -")
        Command.run!(*arguments, stdin: source, timeout: timeout)
      end

      def helper(volumes:, script:, arguments: [], timeout: 300, user: "0:0")
        command = [ "docker", "run", "--rm", "--network", "none", "--label", "#{LABEL}=#{@project}", "--user", user ]
        volumes.each { |source, target, mode| command.push("--volume", "#{source}:#{target}:#{mode}") }
        command.push(HELPER_IMAGE, "sh", "-c", script, "sh", *arguments.map(&:to_s))
        Command.capture(*command, timeout: timeout)
      end

      ACTIVE_STATES = %w[running paused restarting].freeze

      def containers_mounting(path, active_only: false)
        listing = Command.run!("docker", "ps", "--all", "--no-trunc", "--format", "{{.ID}}")
        ids = listing.split
        return [] if ids.empty?

        inspected = JSON.parse(Command.run!("docker", "inspect", *ids))
        target = File.expand_path(path)
        inspected.select do |container|
          mounts = container.fetch("Mounts", []).any? { |mount| overlaps?(File.expand_path(mount.fetch("Source", "/")), target) }
          mounts && (!active_only || ACTIVE_STATES.include?(container.dig("State", "Status")))
        end.map { |container| container.fetch("Id")[0, 12] }
      end

      def cleanup
        owned = Command.capture("docker", "ps", "--all", "--quiet", "--filter", "label=#{LABEL}=#{@project}").output.split
        Command.capture("docker", "rm", "--force", *owned) unless owned.empty?
        @containers.clear
      end

      private

      def overlaps?(left, right)
        left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
      end
    end
  end
end
