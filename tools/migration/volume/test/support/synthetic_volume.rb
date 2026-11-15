# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "sqlite3"
require_relative "../../lib/layout"
require_relative "../../lib/volume_state"

module Migration
  module Volume
    class SyntheticVolume
      attr_reader :root, :storage, :media

      def initialize(root)
        @root = root
        @storage = File.join(root, "storage")
        @media = File.join(root, "media")
        FileUtils.mkdir_p([ @storage, @media ])
      end

      def build
        primary do |database|
          database.execute("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, password_digest TEXT, otp_secret TEXT, last_seen_at TEXT)")
          database.execute("CREATE TABLE notes (body TEXT)")
          database.execute("CREATE TABLE schema_migrations (version TEXT PRIMARY KEY)")
          database.execute("CREATE INDEX index_users_on_name ON users (name)")
          database.execute("INSERT INTO users (name, password_digest, otp_secret, last_seen_at) VALUES ('ada', 'digest-a', '{\"p\":\"AAAA\",\"h\":{}}', '2026-01-01'), ('bob', 'digest-b', NULL, NULL)")
          database.execute("INSERT INTO notes (body) VALUES ('secret-note-body')")
          database.execute("INSERT INTO schema_migrations (version) VALUES ('1')")
        end
        queue do |database|
          database.execute("CREATE TABLE solid_queue_jobs (id INTEGER PRIMARY KEY, class_name TEXT, queue_name TEXT, arguments TEXT, finished_at TEXT)")
          database.execute("CREATE TABLE solid_queue_ready_executions (id INTEGER PRIMARY KEY, job_id INTEGER)")
          database.execute("CREATE TABLE solid_queue_processes (id INTEGER PRIMARY KEY, last_heartbeat_at TEXT)")
          database.execute("INSERT INTO solid_queue_jobs (id, class_name, queue_name, arguments) VALUES (1, 'KnownJob', 'default', 'ARGS-SENTINEL'), (2, 'Vendor::UnknownJob', 'vendor', 'ARGS-SENTINEL')")
          database.execute("INSERT INTO solid_queue_ready_executions (job_id) VALUES (1), (2)")
        end
        [ Layout::CABLE, Layout::CACHE ].each { |name| open(name) { |database| database.execute("CREATE TABLE entries (id INTEGER PRIMARY KEY, value TEXT)") } }
        File.write(File.join(@storage, Layout::SECRET_KEY_BASE), "synthetic-secret-key-base-value\n", perm: 0o600)
        File.write(File.join(@storage, Layout::ENCRYPTION_KEYS), "export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=\"synthetic\"\n", perm: 0o600)
        FileUtils.mkdir_p(File.join(@media, "library"))
        File.binwrite(File.join(@media, "library", "book.epub"), "synthetic epub")
        File.utime(Time.at(1_600_000_000, 7, :nsec), Time.at(1_600_000_000, 7, :nsec), File.join(@media, "library", "book.epub"))
        File.symlink("/elsewhere/target.epub", File.join(@media, "library", "linked.epub"))
        self
      end

      def primary(&block) = open(Layout::PRIMARY, &block)
      def queue(&block) = open(Layout::QUEUE, &block)

      def open(name)
        database = SQLite3::Database.new(File.join(@storage, name))
        database.execute("PRAGMA journal_mode = WAL")
        yield database
      ensure
        database&.close
      end

      def capture(scratch)
        VolumeState.capture(storage: @storage, media: { "/library-root" => @media }, scratch: scratch)
      end

      def copy_to(destination)
        raise "copy failed" unless system("cp", "-a", @root, destination)

        self.class.new(destination)
      end
    end
  end
end
