# frozen_string_literal: true

require "fileutils"
require "sqlite3"
require "tmpdir"
require_relative "scratch"

module Migration
  module Volume
    module SafeCopy
      module_function

      def open(storage, name, scratch: Scratch.root)
        Dir.mktmpdir("m2-copy-", scratch) do |directory|
          [ "", "-wal" ].each do |suffix|
            source = File.join(storage, "#{name}#{suffix}")
            FileUtils.cp(source, File.join(directory, "#{name}#{suffix}")) if File.file?(source)
          end
          database = SQLite3::Database.new(File.join(directory, name))
          begin
            yield database
          ensure
            database.close
          end
        end
      end
    end
  end
end
