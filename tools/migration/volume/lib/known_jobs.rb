# frozen_string_literal: true

require "json"
require_relative "command"

module Migration
  module Volume
    module KnownJobs
      SCRIPT = File.expand_path("../rails/known_job_classes.rb", __dir__)
      DUMMY_ENVIRONMENT = { "SECRET_KEY_BASE_DUMMY" => "1", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "dummy-primary", "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "dummy-deterministic",
                            "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "dummy-salt" }.freeze

      module_function

      def from_image(image)
        arguments = [ "docker", "run", "--rm", "--interactive", "--network", "none", "--user", "1000:1000", "--tmpfs", "/rails/storage:rw,uid=1000,mode=700", "--entrypoint", "./bin/rails" ]
        DUMMY_ENVIRONMENT.each { |key, value| arguments.push("--env", "#{key}=#{value}") }
        arguments.push(image, "runner", "-")
        output = Command.run!(*arguments, stdin: File.read(SCRIPT), timeout: 180)
        line = output.lines.reverse.find { |candidate| candidate.start_with?("M2-RESULT ") }
        raise CommandFailed, "the image reported no job classes" unless line

        JSON.parse(line.delete_prefix("M2-RESULT "))
      end
    end
  end
end
