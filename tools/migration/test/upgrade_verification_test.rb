# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/database_snapshot"
require_relative "../lib/upgrade_verification"

class UpgradeVerificationTest < Minitest::Test
  Verification = Migration::UpgradeVerification

  RELEASED = [
    'CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY)',
    "INSERT INTO schema_migrations VALUES ('1'), ('2')",
    'CREATE TABLE "people" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "score" float, "note" blob)',
    'CREATE TABLE "notes" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "person_id" integer NOT NULL, CONSTRAINT fk_person FOREIGN KEY ("person_id") REFERENCES "people" ("id"))',
    "CREATE INDEX index_people_on_name ON people (name)",
    "INSERT INTO people (id, name, score, note) VALUES (4, 'Ana Ünï', 0.1, x'00ff'), (9, 'Bo', NULL, NULL)",
    "INSERT INTO notes (id, person_id) VALUES (1, 4)",
    "INSERT INTO people (id, name) VALUES (99, 'gone')",
    "DELETE FROM people WHERE id = 99"
  ].freeze

  UPGRADE = [
    "INSERT INTO schema_migrations VALUES ('3')",
    'ALTER TABLE people ADD COLUMN "nickname" varchar',
    'CREATE TABLE "extras" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL)'
  ].freeze

  def setup
    @scratch = Dir.mktmpdir("upgrade-verification", ENV.fetch("TMPDIR", Dir.home))
    @before = snapshot("before", RELEASED)
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def snapshot(name, statements)
    path = File.join(@scratch, "#{name}.sqlite3")
    database = SQLite3::Database.new(path)
    statements.each { |statement| database.execute(statement) }
    database.close
    Migration::DatabaseSnapshot.read(path)
  end

  def expectations
    Verification::Expectations.new(new_tables: [ "extras" ], added_columns: { "people" => [ "nickname" ] }, added_indexes: {}, versions_before: %w[1 2], versions_after: %w[1 2 3])
  end

  def findings_for(*extra)
    Verification.verify!(before: @before, after: snapshot("after-#{extra.hash}", RELEASED + UPGRADE + extra), expectations: expectations)
    []
  rescue Verification::Failed => error
    error.findings
  end

  def test_accepts_an_additive_upgrade_and_counts_preserved_rows
    counts = Verification.verify!(before: @before, after: snapshot("good", RELEASED + UPGRADE), expectations: expectations)
    assert_equal({ "rows" => 2, "preserved" => 2 }, counts.fetch("people"))
    assert_equal({ "rows" => 1, "preserved" => 1 }, counts.fetch("notes"))
  end

  def test_rejects_a_float_that_changed_in_the_last_bit
    assert_includes findings_for("UPDATE people SET score = 0.10000000000000002 WHERE id = 4"), "value-changed:people:[4]:score"
  end

  def test_rejects_a_blob_that_became_text
    assert_includes findings_for("UPDATE people SET note = CAST(note AS TEXT) WHERE id = 4"), "value-changed:people:[4]:note"
  end

  def test_rejects_a_null_that_became_an_empty_string
    assert_includes findings_for("UPDATE people SET note = '' WHERE id = 9"), "value-changed:people:[9]:note"
  end

  def test_rejects_a_value_written_into_a_new_column_of_an_old_row
    assert_includes findings_for("UPDATE people SET nickname = 'x' WHERE id = 4"), "added-column-not-null:people:[4]:nickname"
  end

  def test_rejects_an_unlisted_column_or_index_on_an_old_table
    assert_includes findings_for('ALTER TABLE notes ADD COLUMN "extra" integer'), "column-unexpected:notes.extra"
    assert_includes findings_for("CREATE INDEX index_notes_unlisted ON notes (person_id)"), "index-unexpected:notes.index_notes_unlisted"
  end

  def test_rejects_a_changed_table_definition_that_keeps_every_value
    after = snapshot("rebuilt", RELEASED.map { |statement| statement.sub('"name" varchar NOT NULL', '"name" text NOT NULL') } + UPGRADE)
    error = assert_raises(Verification::Failed) { Verification.verify!(before: @before, after: after, expectations: expectations) }
    assert_includes error.findings, "column-changed:people.name"
  end

  def test_rejects_a_lost_foreign_key
    rebuilt = RELEASED.map { |statement| statement.sub(', CONSTRAINT fk_person FOREIGN KEY ("person_id") REFERENCES "people" ("id")', "") }
    error = assert_raises(Verification::Failed) { Verification.verify!(before: @before, after: snapshot("no-fk", rebuilt + UPGRADE), expectations: expectations) }
    assert_includes error.findings, "foreign-keys-changed:notes"
    assert_includes error.findings, "definition-changed:notes"
  end

  def test_rejects_a_reused_autoincrement_identifier
    assert_includes findings_for("UPDATE sqlite_sequence SET seq = 9 WHERE name = 'people'"), "sequence-changed:people"
  end

  def test_rejects_unexpected_new_data_in_a_new_table
    assert_includes findings_for("INSERT INTO extras DEFAULT VALUES"), "new-table-not-empty:extras"
  end
end
