# frozen_string_literal: true

require "digest"
require_relative "layout"

module Migration
  module Volume
    Violation = Data.define(:area, :subject, :reason) do
      def to_s = "#{area}:#{subject}:#{reason}"
    end

    Allowances = Data.define(:mutable_columns, :new_row_tables, :new_tables, :added_columns, :new_tables_empty, :volatile_files) do
      def self.none
        new(mutable_columns: {}, new_row_tables: [], new_tables: false, added_columns: {}, new_tables_empty: false, volatile_files: [])
      end

      def merge(**changes) = with(**changes)
    end

    class Comparison
      REPORT_LIMIT = 25
      FILE_FIELDS = %i[kind mode uid gid size mtime_ns inode digest target].freeze
      MEDIA_FIELDS = %i[kind mode uid gid size mtime_ns ctime_ns inode digest target].freeze

      def self.call(before, after, allowances: Allowances.none)
        new(before, after, allowances).violations
      end

      def initialize(before, after, allowances)
        @before = before
        @after = after
        @allowances = allowances
        @violations = []
      end

      def violations
        databases
        files
        media
        @violations
      end

      private

      def label(key, keyed)
        keyed && key.bytesize <= 40 ? key : Digest::SHA256.hexdigest(key)[0, 12]
      end

      def add(area, subject, reason)
        @violations << Violation.new(area: area, subject: subject, reason: reason)
      end

      def databases
        Layout::DATABASES.each do |name|
          earlier = @before.databases.fetch(name)
          later = @after.databases.fetch(name)
          next if earlier.nil? && later.nil?
          next add(name, "file", "database-lost") if later.nil?
          next add(name, "integrity", "not-ok") unless later.integrity == [ "ok" ]
          next if earlier.nil?

          compare_database(name, earlier, later)
        end
      end

      def compare_database(name, earlier, later)
        ignored = name == Layout::QUEUE ? Layout::RUNTIME_QUEUE_TABLES : []
        return if [ Layout::CABLE, Layout::CACHE ].include?(name)

        earlier.tables.each do |table, before_table|
          next if ignored.include?(table)

          after_table = later.tables[table]
          next add(name, table, "table-lost") unless after_table

          compare_table(name, table, before_table, after_table)
        end
        sequences(name, earlier, later)
        added_tables(name, earlier, later, ignored)
      end

      def compare_table(database, table, before, after)
        subject = table
        keyed = before.columns.any? { |column| column["pk"].positive? }
        before_columns = before.columns.map { |column| column["name"] }
        after_columns = after.columns.map { |column| column["name"] }
        (before_columns - after_columns).each { |column| add(database, "#{subject}.#{column}", "column-lost") }
        (after_columns - before_columns - Array(@allowances.added_columns[table])).each { |column| add(database, "#{subject}.#{column}", "column-added") }
        (before.indexes.keys - after.indexes.keys).each { |index| add(database, "#{subject}##{index}", "index-lost") }
        mutable = Array(@allowances.mutable_columns[table])
        before.rows.each do |key, cells|
          row = after.rows[key]
          next add(database, "#{subject}[#{label(key, keyed)}]", "row-lost") unless row

          (before_columns & after_columns).each do |column|
            add(database, "#{subject}[#{label(key, keyed)}].#{column}", "value-changed") if cells.fetch(column) != row.fetch(column) && !mutable.include?(column)
          end
        end
        return if @allowances.new_row_tables.include?(table)

        (after.rows.keys - before.rows.keys).each { |key| add(database, "#{subject}[#{label(key, keyed)}]", "row-added") }
      end

      def sequences(database, earlier, later)
        earlier.sequences.each do |table, value|
          add(database, "sqlite_sequence.#{table}", "counter-reset") if later.sequences.fetch(table, 0) < value
        end
      end

      def added_tables(database, earlier, later, ignored)
        (later.tables.keys - earlier.tables.keys - ignored).each do |table|
          next add(database, table, "table-added") unless @allowances.new_tables

          add(database, table, "new-table-not-empty") if @allowances.new_tables_empty && !later.tables[table].rows.empty?
        end
      end

      def files
        @before.files.each do |name, entry|
          next if Layout.database?(name) || Layout.sidecar?(name) || @allowances.volatile_files.include?(name)

          later = @after.files[name]
          next add("files", name, "file-lost") unless later

          differing = FILE_FIELDS.reject { |field| entry.public_send(field) == later.public_send(field) }
          add("files", name, "changed:#{differing.join(',')}") unless differing.empty?
        end
        (@after.files.keys - @before.files.keys).each do |name|
          add("files", name, "file-added") unless Layout.sidecar?(name) || @allowances.volatile_files.include?(name) || Layout.database?(name)
        end
      end

      def media
        @before.media.each do |root, entries|
          later_entries = @after.media.fetch(root)
          entries.each do |name, entry|
            later = later_entries[name]
            next add("media:#{root}", name, "file-lost") unless later

            differing = MEDIA_FIELDS.reject { |field| entry.public_send(field) == later.public_send(field) }
            add("media:#{root}", name, "changed:#{differing.join(',')}") unless differing.empty?
          end
          (later_entries.keys - entries.keys).each { |name| add("media:#{root}", name, "file-added") }
        end
      end
    end
  end
end
