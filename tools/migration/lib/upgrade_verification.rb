# frozen_string_literal: true

module Migration
  module UpgradeVerification
    class Failed < StandardError
      attr_reader :findings

      def initialize(findings)
        @findings = findings
        super("upgrade verification failed: #{findings.first(20).join(', ')}")
      end
    end

    Expectations = Data.define(:new_tables, :added_columns, :added_indexes, :versions_before, :versions_after)

    ADDED_COLUMNS = { "api_tokens" => %w[issued_via replaces_api_token_id connection_key] }.freeze
    ADDED_INDEXES = { "api_tokens" => %w[index_api_tokens_on_user_id_and_connection_key], "books" => %w[index_books_on_consumer_title] }.freeze
    GROWING_TABLES = %w[schema_migrations].freeze

    module_function

    def verify!(before:, after:, expectations:)
      findings = []
      findings.concat(integrity(after))
      findings.concat(table_set(before, after, expectations))
      findings.concat(versions(before, after, expectations))
      before.tables.each_value { |table| findings.concat(preserved(table, after.tables[table.name], expectations)) }
      findings.concat(new_tables(after, expectations))
      findings.concat(sequences(before, after))
      findings << "user-version-changed" unless before.user_version == after.user_version
      raise Failed, findings unless findings.empty?

      counts(before, after)
    end

    def integrity(after)
      after.integrity == [ "ok" ] ? [] : [ "integrity-check-failed" ]
    end

    def table_set(before, after, expectations)
      expected = (before.tables.keys + expectations.new_tables).sort
      actual = after.tables.keys.sort
      (expected - actual).map { |name| "table-lost:#{name}" } + (actual - expected).map { |name| "table-unexpected:#{name}" }
    end

    def versions(before, after, expectations)
      recorded_before = column_values(before, "schema_migrations", "version")
      recorded_after = column_values(after, "schema_migrations", "version")
      findings = []
      findings << "versions-before-differ-from-release" unless recorded_before == expectations.versions_before.sort
      findings << "versions-after-differ-from-checkout" unless recorded_after == expectations.versions_after.sort
      findings << "release-versions-lost" unless (recorded_before - recorded_after).empty?
      findings
    end

    def column_values(snapshot, table, column)
      return [] unless snapshot.tables.key?(table)

      snapshot.tables.fetch(table).rows.values.map { |row| row.fetch(column).last }.sort
    end

    def preserved(old, current, expectations)
      return [] if current.nil?

      findings = []
      added = expectations.added_columns.fetch(old.name, [])
      findings.concat(columns(old, current, added))
      findings << "definition-changed:#{old.name}" if added.empty? && old.definition != current.definition
      findings.concat(rows(old, current, added))
      findings.concat(indexes(old, current, expectations.added_indexes.fetch(old.name, [])))
      findings << "foreign-keys-changed:#{old.name}" unless old.foreign_keys == current.foreign_keys
      findings
    end

    def columns(old, current, added)
      old_columns = old.columns.to_h { |column| [ column["name"], column ] }
      new_columns = current.columns.to_h { |column| [ column["name"], column ] }
      findings = old_columns.filter_map { |name, column| "column-changed:#{old.name}.#{name}" unless new_columns[name] == column }
      extra = new_columns.keys - old_columns.keys
      findings += (extra - added).map { |name| "column-unexpected:#{old.name}.#{name}" }
      findings += (added - extra).map { |name| "column-missing:#{old.name}.#{name}" }
      findings += added.filter_map do |name|
        column = new_columns[name]
        "column-default:#{old.name}.#{name}" if column && !(column["default"].nil? && column["notnull"].zero?)
      end
      findings
    end

    def rows(old, current, added)
      findings = []
      kept = old.columns.map { |column| column["name"] }
      old.rows.each do |key, row|
        found = current.rows[key]
        if found.nil?
          findings << "row-lost:#{old.name}:#{key}"
          next
        end
        kept.each { |name| findings << "value-changed:#{old.name}:#{key}:#{name}" unless found[name] == row[name] }
        added.each { |name| findings << "added-column-not-null:#{old.name}:#{key}:#{name}" unless found[name] == [ "null", nil ] }
      end
      extra = current.rows.keys - old.rows.keys
      findings << "rows-added:#{old.name}:#{extra.size}" unless extra.empty? || GROWING_TABLES.include?(old.name)
      findings
    end

    def indexes(old, current, added)
      findings = old.indexes.filter_map { |name, definition| "index-changed:#{old.name}.#{name}" unless current.indexes[name] == definition }
      extra = current.indexes.keys - old.indexes.keys
      findings += (extra - added).map { |name| "index-unexpected:#{old.name}.#{name}" }
      findings + (added - extra).map { |name| "index-missing:#{old.name}.#{name}" }
    end

    def new_tables(after, expectations)
      expectations.new_tables.filter_map do |name|
        table = after.tables[name]
        "new-table-not-empty:#{name}" if table && !table.rows.empty?
      end
    end

    def sequences(before, after)
      before.sequences.filter_map { |name, value| "sequence-changed:#{name}" unless after.sequences[name] == value }
    end

    def counts(before, after)
      before.tables.to_h do |name, table|
        [ name, { "rows" => table.rows.size, "preserved" => table.rows.size - (table.rows.keys - after.tables.fetch(name).rows.keys).size } ]
      end
    end
  end
end
