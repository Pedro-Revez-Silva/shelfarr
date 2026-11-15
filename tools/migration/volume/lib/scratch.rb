# frozen_string_literal: true

require "fileutils"

module Migration
  module Volume
    class ScratchRefused < StandardError; end

    module Scratch
      RAM_BACKED = %w[/tmp /dev/shm].freeze

      module_function

      def root(environment = ENV)
        path = environment["SHELFARR_MIGRATION_SCRATCH"] || environment["TMPDIR"] || File.join(Dir.home, ".cache", "agent-tmp")
        expanded = File.expand_path(path)
        raise ScratchRefused, "refusing RAM-backed scratch #{expanded}" if RAM_BACKED.any? { |ram| expanded == ram || expanded.start_with?("#{ram}/") }

        FileUtils.mkdir_p(expanded)
        expanded
      end
    end
  end
end
