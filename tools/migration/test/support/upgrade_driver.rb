# frozen_string_literal: true

require "json"
require_relative "../../lib/producer_boot"

REPO_ROOT = File.expand_path("../../../..", __dir__)
scenario = ARGV.fetch(0)
out = ARGV.fetch(1)

paths = Migration::ProducerBoot.call(out: out, repo_root: REPO_ROOT)
require_relative "../../lib/stable_upgrade_builder"

class MinimalRecords
  def initialize(connection:, **)
    @connection = connection
  end

  def call
    @connection.exec_query("INSERT INTO users (id, username, password_digest, created_at, updated_at) VALUES (1, 'solo', 'not-a-real-digest', '2026-10-01 00:00:00', '2026-10-01 00:00:00')")
    Migration::ReleasedRecords::Result.new(passwords: {}, raw_tokens: {}, seeded_tables: [ "users" ])
  end
end

options = scenario == "sparse" ? { records: MinimalRecords, complete: false } : {}
builder = Migration::StableUpgradeBuilder.new(paths: paths, repo_root: REPO_ROOT)
run = builder.prepare_run(**options)
run.resolve_release
run.build_released_database
run.seal_source

def mid_state(run)
  run.release_database
  current = Migration::DatabaseSnapshot.read(run.database_path)
  findings = run.before.tables.values.flat_map { |table| Migration::UpgradeVerification.preserved(table, current.tables[table.name], run.expectations) }
  versions = current.tables.fetch("schema_migrations").rows.values.map { |row| row.fetch("version").last }.max
  { "released_findings" => findings, "highest_version" => versions, "tables" => current.tables.keys.sort, "digest" => current.digest }
end

def finish(run, applied)
  after = run.verify(applied)
  run.repeat_is_safe(after)
  { "applied" => applied.size, "verified" => true, "before_digest" => run.before.digest, "after_digest" => after.digest }
end

def attempt
  yield
  nil
rescue Migration::StableUpgrade::Failed => error
  { "stage" => error.stage, "version" => error.version, "applied" => error.applied, "message" => error.message }
end

facts =
  case scenario
  when "complete", "sparse"
    finish(run, run.migrate)
  when "blocker"
    ActiveRecord::Base.with_connection { |connection| connection.execute("CREATE TABLE kobo_account_shares (blocker integer)") }
    failure = attempt { run.migrate }
    middle = mid_state(run)
    middle["rights_column_present"] = ActiveRecord::Base.with_connection { |connection| connection.columns("kobo_account_books").map(&:name).include?("rights") }
    ActiveRecord::Base.with_connection { |connection| connection.execute("DROP TABLE kobo_account_shares") }
    { "failure" => failure, "middle" => middle, "resumed" => finish(run, run.migrate) }
  when "deadline"
    failure = attempt { run.migrate(budget: -1) }
    { "failure" => failure, "middle" => mid_state(run), "resumed" => finish(run, run.migrate) }
  when "kill"
    run.release_database
    pid = fork do
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        Process.kill("KILL", Process.pid) if payload[:sql].include?('CREATE TABLE "kobo_tags"')
      end
      run.migrate
      exit!(0)
    end
    _, status = Process.wait2(pid)
    { "signaled" => status.signaled?, "signal" => status.termsig, "middle" => mid_state(run), "resumed" => finish(run, run.migrate) }
  when "reload-current-schema"
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Base.with_connection { |connection| connection.disable_referential_integrity { load File.join(REPO_ROOT, "db", "schema.rb") } }
    failure = attempt { run.verify([]) }
    { "failure" => failure }
  when "skip-migrations"
    { "failure" => attempt { run.verify([]) } }
  when "variants"
    applied = run.migrate
    run.release_database
    verified = Migration::DatabaseSnapshot.read(run.database_path)
    JSON.parse(ARGV.fetch(2)).to_h do |name, statements|
      copy = File.join(paths.tmp, "variant-#{name}.sqlite3")
      FileUtils.cp(run.database_path, copy)
      database = SQLite3::Database.new(copy)
      statements.each { |statement| database.execute(statement) }
      database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      database.close
      findings = begin
        Migration::UpgradeVerification.verify!(before: run.before, after: Migration::DatabaseSnapshot.read(copy), expectations: run.expectations)
        []
      rescue Migration::UpgradeVerification::Failed => error
        error.findings
      end
      [ name, findings ]
    end.merge("applied" => applied.size, "verified_digest" => verified.digest)
  else
    raise "unknown scenario"
  end

puts JSON.generate(facts)
