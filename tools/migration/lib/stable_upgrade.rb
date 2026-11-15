# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "stringio"
require "sqlite3"
require_relative "database_snapshot"
require_relative "released_records"
require_relative "release_source"
require_relative "upgrade_verification"

module Migration
  module StableUpgrade
    class Failed < StandardError
      attr_reader :stage, :applied, :version

      def initialize(stage, detail, applied: [], version: nil)
        @stage = stage
        @applied = applied
        @version = version
        super("#{stage}: #{detail}")
      end
    end

    DEFAULT_DEADLINE_SECONDS = 120
    SOURCE_FILE = "released-source.sqlite3"
    TABLE_DECLARATION = /^\s*create_table "([^"]+)"/
    REQUIRED_DEFAULTS = [
      { table: "api_tokens", values: { "name" => "default-probe", "token_digest" => "probe-digest", "token_prefix" => "shf_probe", "created_at" => "2026-11-14 00:00:00", "updated_at" => "2026-11-14 00:00:00" },
        expect: { "scopes" => "[]", "issued_via" => nil, "replaces_api_token_id" => nil, "connection_key" => nil } },
      { table: "kobo_devices", values: { "user_id" => :user, "name" => "probe", "base_url" => "http://127.0.0.1:1", "token_digest" => "probe-device", "created_at" => "2026-11-14 00:00:00", "updated_at" => "2026-11-14 00:00:00" },
        expect: { "sync_revision" => 0, "store_coexistence" => 0, "share_progress" => 0, "receive_progress" => 0, "store_status" => nil } },
      { table: "consumer_reading_states", values: { "user_id" => :user, "book_id" => :book, "created_at" => "2026-11-14 00:00:00", "updated_at" => "2026-11-14 00:00:00" }, expect: { "status" => 0 } },
      { table: "consumer_progresses", values: { "user_id" => :user, "book_id" => :book, "asset_id" => "probe", "client_mutation_id" => "probe", "created_at" => "2026-11-14 00:00:00", "updated_at" => "2026-11-14 00:00:00" },
        expect: { "version" => 1, "observed_at" => nil, "locator" => nil } }
    ].freeze

    Upgraded = Data.define(:release, :before, :after, :applied, :source_sha256, :counts, :schema_before, :schema_after)

    class Run
      def initialize(paths:, repo_root:, root:, media:, legacy_context:, deadline: DEFAULT_DEADLINE_SECONDS, records: ReleasedRecords, complete: true)
        @paths = paths
        @repo_root = repo_root
        @root = root
        @media = media
        @legacy_context = legacy_context
        @deadline = deadline
        @records_class = records
        @complete = complete
        @release = ReleaseSource.new(repo_root)
      end

      attr_reader :release, :records, :before, :source_path

      def database_path
        @paths.primary_db
      end

      def call
        resolve_release
        build_released_database
        seal_source
        applied = migrate
        after = verify(applied)
        Upgraded.new(release: @release, before: @before, after: after, applied: applied, source_sha256: @source_sha256, counts: @counts,
                     schema_before: @released_schema_sha, schema_after: @current_schema_sha)
      end

      def resolve_release
        @release.resolve!
        @new_versions = @release.new_migrations(File.join(@repo_root, "db", "migrate"))
      rescue ReleaseSource::Unavailable => error
        raise Failed.new("release", error.message)
      end

      def build_released_database
        ActiveRecord::Migration.verbose = false
        schema_file = File.join(@paths.tmp, "released-schema.rb")
        File.write(schema_file, @release.schema_ruby, perm: 0o600)
        load schema_file
        FileUtils.rm_f(schema_file)
        require_released_shape
        ActiveRecord::Base.with_connection do |connection|
          connection.transaction { @records = @records_class.new(connection: connection, root: @root, media: @media, legacy_context: @legacy_context).call }
        end
        release_database
        @before = DatabaseSnapshot.read(@paths.primary_db)
        require_every_table_seeded if @complete
      end

      def seal_source
        @source_path = File.join(File.dirname(@paths.primary_db), SOURCE_FILE)
        copy_with_backup_api(@paths.primary_db, @source_path)
        FileUtils.chmod(0o440, @source_path)
        @source_sha256 = Digest::SHA256.file(@source_path).hexdigest
        sealed = DatabaseSnapshot.read(@source_path)
        raise Failed.new("source", "the sealed released snapshot differs from the database that will be upgraded") unless sealed.digest == @before.digest
      end

      def migrate(budget: @deadline)
        context = migration_context
        applied = []
        started = clock
        with_watchdog(budget) do
          pending_versions(context).each do |version|
            raise Failed.new("migration", "deadline of #{budget} seconds exceeded", applied: applied) if clock - started > budget

            begin
              context.up(version)
            rescue StandardError => error
              raise Failed.new("migration", "#{version} raised #{error.class.name}; #{applied.size} of #{applied.size + pending_versions(context).size} applied", applied: applied, version: version.to_s)
            end
            applied << version.to_s
          end
        end
        applied
      end

      def verify(applied)
        raise Failed.new("migration", "migrations still pending after upgrade", applied: applied) unless pending_versions(migration_context).empty?

        reset_models
        @current_schema_sha = check_schema_matches_checkout
        release_database
        after = DatabaseSnapshot.read(@paths.primary_db)
        @counts = UpgradeVerification.verify!(before: @before, after: after, expectations: expectations)
        check_defaults_and_identifier_continuity
        after
      rescue UpgradeVerification::Failed => error
        raise Failed.new("verification", error.message, applied: applied)
      end

      def repeat_is_safe(after)
        context = migration_context
        context.migrate
        release_database
        again = DatabaseSnapshot.read(@paths.primary_db)
        raise Failed.new("repeat", "a second migration run changed the upgraded database") unless again.digest == after.digest
        raise Failed.new("repeat", "migrations became pending again") unless pending_versions(context).empty?
      end

      def expectations
        UpgradeVerification::Expectations.new(
          new_tables: schema_tables(File.read(File.join(@repo_root, "db", "schema.rb"))) - schema_tables(@release.schema_ruby),
          added_columns: UpgradeVerification::ADDED_COLUMNS, added_indexes: UpgradeVerification::ADDED_INDEXES,
          versions_before: @release.versions, versions_after: @release.versions + @new_versions
        )
      end

      def release_database
        ActiveRecord::Base.with_connection { |connection| connection.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        ActiveRecord::Base.connection_handler.clear_all_connections!
        leftovers = Dir.glob("#{@paths.primary_db}-*")
        raise Failed.new("database", "sidecar files remain after checkpoint") unless leftovers.empty?
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      WATCHDOG = <<~SH
        end=$(( $(date +%s) + $1 ))
        while kill -0 "$2" 2>/dev/null; do
          if [ "$(date +%s)" -ge "$end" ]; then
            printf '%s\\n' "upgrade failed: migration: deadline of $1 seconds exceeded; the database is left for SQLite to recover" >&2
            kill -KILL "$2"
            exit 0
          fi
          sleep 0.2
        done
      SH

      def with_watchdog(budget)
        watchdog = budget.positive? ? Process.spawn("sh", "-c", WATCHDOG, "watchdog", budget.ceil.to_s, Process.pid.to_s, pgroup: true, in: :close, out: :close) : nil
        yield
      ensure
        stop_watchdog(watchdog)
      end

      def stop_watchdog(watchdog)
        return unless watchdog

        Process.kill("TERM", -watchdog)
        Process.wait(watchdog)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def migration_context
        ActiveRecord::Base.connection_pool.migration_context
      end

      def pending_versions(context)
        applied = context.get_all_versions
        context.migrations.map(&:version).reject { |version| applied.include?(version) }.sort
      end

      def schema_tables(text)
        text.scan(TABLE_DECLARATION).flatten.sort
      end

      def dump_schema
        io = StringIO.new
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)
        io.string.lines.drop_while { |line| line.start_with?("#") || line.strip.empty? }.join
      end

      def require_released_shape
        dumped = dump_schema
        released = @release.schema_ruby
        raise Failed.new("source", "the loaded database does not dump back to the released schema") unless dumped.strip == released.strip

        recorded = ActiveRecord::Base.connection_pool.migration_context.get_all_versions.map(&:to_s).sort
        raise Failed.new("source", "schema_migrations of the released database differ from the release tree") unless recorded == @release.versions
        raise Failed.new("source", "consumer tables exist in the released database") if dumped.include?("consumer_progresses")

        @released_schema_sha = Digest::SHA256.hexdigest(dumped)
      end

      def require_every_table_seeded
        empty = @before.tables.reject { |name, table| %w[schema_migrations ar_internal_metadata].include?(name) || !table.rows.empty? }.keys
        raise Failed.new("source", "released tables without any record: #{empty.join(', ')}") unless empty.empty?
      end

      def check_schema_matches_checkout
        dumped = dump_schema
        raise Failed.new("verification", "the upgraded database does not dump to the checkout db/schema.rb") unless dumped.strip == File.read(File.join(@repo_root, "db", "schema.rb")).strip

        Digest::SHA256.hexdigest(dumped)
      end

      def reset_models
        ActiveRecord::Base.connection_pool.schema_cache.clear!
        ActiveRecord::Base.descendants.each(&:reset_column_information)
      end

      def copy_with_backup_api(from, to)
        source = SQLite3::Database.new(DatabaseSnapshot.immutable_uri(from), flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
        destination = SQLite3::Database.new(to)
        backup = SQLite3::Backup.new(destination, "main", source, "main")
        backup.step(-1)
        backup.finish
        destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      ensure
        destination&.close
        source&.close
        leftovers = Dir.glob("#{to}-*")
        raise Failed.new("source", "sidecar files remain after sealing the snapshot") unless leftovers.empty?
      end

      def check_defaults_and_identifier_continuity
        ActiveRecord::Base.with_connection do |connection|
          connection.transaction(requires_new: true) do
            user = connection.insert("INSERT INTO users (username, password_digest, created_at, updated_at) VALUES ('probe-owner', 'probe', '2026-11-14 00:00:00', '2026-11-14 00:00:00')")
            book = connection.insert("INSERT INTO books (title, book_type, created_at, updated_at) VALUES ('probe', 1, '2026-11-14 00:00:00', '2026-11-14 00:00:00')")
            REQUIRED_DEFAULTS.each { |probe| check_default(connection, probe, user, book) }
            raise Failed.new("verification", "a new row reused an identifier from before the upgrade") unless book > @before.sequences.fetch("books", 0)

            raise ActiveRecord::Rollback
          end
        end
        release_database
      end

      def check_default(connection, probe, user, book)
        values = probe[:values].transform_values { |value| { user: user, book: book }.fetch(value, value) }
        names = values.keys
        id = connection.insert("INSERT INTO #{connection.quote_table_name(probe[:table])} (#{names.join(', ')}) VALUES (#{names.map { |name| connection.quote(values[name]) }.join(', ')})")
        row = connection.select_one("SELECT * FROM #{connection.quote_table_name(probe[:table])} WHERE id = #{id.to_i}")
        mismatched = probe[:expect].reject { |column, expected| row[column] == expected }.keys
        raise Failed.new("verification", "defaults differ on #{probe[:table]}: #{mismatched.join(', ')}") unless mismatched.empty?
      end
    end
  end
end
