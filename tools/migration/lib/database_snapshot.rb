# frozen_string_literal: true

require "digest"
require "json"
require "sqlite3"

module Migration
  module DatabaseSnapshot
    Table = Data.define(:name, :definition, :columns, :rows, :indexes, :foreign_keys) do
      def digest
        Digest::SHA256.hexdigest(JSON.generate([ name, definition, columns, rows.keys.sort.map { |key| [ key, rows.fetch(key) ] }, indexes, foreign_keys ]))
      end
    end

    Snapshot = Data.define(:tables, :sequences, :user_version, :integrity) do
      def digest
        Digest::SHA256.hexdigest(JSON.generate([ tables.keys.sort.map { |name| [ name, tables.fetch(name).digest ] }, sequences.sort.to_h, user_version ]))
      end
    end

    INTERNAL_TABLE = /\Asqlite_/

    module_function

    def read(path)
      database = SQLite3::Database.new(immutable_uri(path), flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
      database.execute("PRAGMA query_only = ON")
      build(database)
    ensure
      database&.close
    end

    def immutable_uri(path)
      escaped = path.gsub(%r{[^A-Za-z0-9_\-./]}) { |character| character.bytes.map { |byte| format("%%%02X", byte) }.join }
      "file:#{escaped}?mode=ro&immutable=1"
    end

    def build(database)
      names = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").flatten.reject { |name| INTERNAL_TABLE.match?(name) }
      tables = names.to_h { |name| [ name, table(database, name) ] }
      Snapshot.new(tables: tables, sequences: sequences(database), user_version: database.get_first_value("PRAGMA user_version"),
                   integrity: database.execute("PRAGMA integrity_check").flatten)
    end

    def sequences(database)
      return {} if database.get_first_value("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'").nil?

      database.execute("SELECT name, seq FROM sqlite_sequence").to_h
    end

    def table(database, name)
      quoted = quote(name)
      info = database.execute("PRAGMA table_info(#{quoted})")
      columns = info.map { |_cid, column, type, notnull, default, key| { "name" => column, "type" => type, "notnull" => notnull, "default" => default, "pk" => key } }
      definition = database.get_first_value("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", name)
      Table.new(name: name, definition: definition, columns: columns, rows: rows(database, quoted, columns),
                indexes: indexes(database, name), foreign_keys: foreign_keys(database, quoted))
    end

    def rows(database, quoted, columns)
      names = columns.map { |column| column["name"] }
      projection = names.flat_map { |column| [ "typeof(#{quote(column)})", quote(column) ] }.join(", ")
      keys = columns.select { |column| column["pk"].positive? }.sort_by { |column| column["pk"] }.map { |column| column["name"] }
      database.execute("SELECT #{projection} FROM #{quoted}").to_h do |row|
        cells = names.each_with_index.to_h { |column, index| [ column, canonical(row[index * 2], row[(index * 2) + 1]) ] }
        key = keys.empty? ? cells.values.to_json : keys.map { |column| cells.fetch(column).last }.to_json
        [ key, cells ]
      end
    end

    def canonical(type, value)
      case type
      when "null" then [ "null", nil ]
      when "integer" then [ "integer", value ]
      when "real" then [ "real", [ value ].pack("G").unpack1("H*") ]
      when "blob" then [ "blob", value.unpack1("H*") ]
      else text(value)
      end
    end

    def text(value)
      utf8 = value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? [ "text", utf8 ] : [ "text-bytes", value.unpack1("H*") ]
    end

    def indexes(database, table)
      database.execute("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL ORDER BY name", table).to_h
    end

    def foreign_keys(database, quoted)
      database.execute("PRAGMA foreign_key_list(#{quoted})").map { |row| row[1..] }.sort_by(&:to_json)
    end

    def quote(identifier)
      "\"#{identifier.gsub('"', '""')}\""
    end
  end
end
