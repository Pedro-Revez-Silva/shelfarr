# frozen_string_literal: true

require "open3"

module Migration
  module Volume
    class CommandFailed < StandardError; end
    class CommandTimedOut < CommandFailed; end

    module Command
      Result = Data.define(:output, :error, :status) do
        def success? = status.success?
      end

      OUTPUT_LIMIT = 1_048_576

      module_function

      def capture(*command, stdin: nil, timeout: 120, environment: {}, limit: OUTPUT_LIMIT)
        Open3.popen3(environment, *command, pgroup: true) do |input, out, err, thread|
          writer = Thread.new { stdin.nil? ? nil : input.write(stdin) }
          readers = [ out, err ].map { |stream| Thread.new { read_bounded(stream, limit) } }
          writer.join(timeout)
          begin
            input.close
          rescue IOError, Errno::EPIPE
            nil
          end
          unless thread.join(timeout)
            Process.kill("KILL", -thread.pid)
            thread.join
            raise CommandTimedOut, "#{command.first} #{command[1]} exceeded #{timeout}s"
          end
          Result.new(output: readers[0].value, error: readers[1].value, status: thread.value)
        end
      end

      def read_bounded(stream, limit)
        buffer = +""
        while (chunk = stream.read(16_384))
          buffer << chunk if buffer.bytesize < limit
        end
        buffer
      end

      def summary(error)
        lines = error.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("from ") }
        (lines.first || error.lines.last.to_s.strip)[0, 300]
      end

      def run!(*command, **options)
        result = capture(*command, **options)
        raise CommandFailed, "#{command.first} #{command[1]} exited #{result.status.exitstatus}: #{summary(result.error)}" unless result.success?

        result.output
      end
    end
  end
end
