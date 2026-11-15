# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "sqlite3"
require "tmpdir"

class StableUpgradeTest < Minitest::Test
  REPO = File.expand_path("../../..", __dir__)
  DRIVER = File.expand_path("support/upgrade_driver.rb", __dir__)
  PRODUCER = File.join(REPO, "tools", "migration", "produce_fixture.rb")
  PINNED_COMMIT = "96333c6674a21701f7229c1a51038dc3b117c1a0"
  RELEASED_VERSION = "20261102120000"
  CURRENT_VERSION = "20261112150000"
  NEW_TABLES = %w[consumer_device_grants consumer_progresses consumer_reading_states kobo_account_book_files kobo_account_books kobo_account_shares kobo_accounts kobo_deliveries kobo_devices kobo_kepub_copies
                  kobo_local_entitlements kobo_tags read_along_alignments].freeze
  FIRST_BLOCKED_VERSION = "20261109020000"
  LAST_VERSION_BEFORE_BLOCK = "20261109010000"

  def setup
    @scratch = Dir.mktmpdir("stable-upgrade", ENV.fetch("TMPDIR", Dir.home))
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def environment
    { "HOME" => Dir.home, "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8" }
  end

  def drive(scenario, *extra)
    output, status = Open3.capture2e(environment, "bundle", "exec", "ruby", DRIVER, scenario, File.join(@scratch, scenario), *extra, chdir: REPO, unsetenv_others: true)
    assert status.success?, output
    JSON.parse(output.lines.last)
  rescue JSON::ParserError
    flunk "driver produced no facts: #{output.lines.last(5).join}"
  end

  def test_the_shipped_migrations_upgrade_a_released_database_and_a_second_run_changes_nothing
    facts = drive("complete")
    assert_equal 17, facts.fetch("applied")
    assert facts.fetch("verified")
    refute_equal facts.fetch("before_digest"), facts.fetch("after_digest")
  end

  def test_a_failing_migration_rolls_back_alone_and_the_upgrade_resumes
    facts = drive("blocker")
    failure = facts.fetch("failure")
    assert_equal "migration", failure.fetch("stage")
    assert_equal FIRST_BLOCKED_VERSION, failure.fetch("version")
    assert_equal 12, failure.fetch("applied").size
    assert_equal LAST_VERSION_BEFORE_BLOCK, failure.fetch("applied").last
    middle = facts.fetch("middle")
    assert_equal LAST_VERSION_BEFORE_BLOCK, middle.fetch("highest_version")
    assert_empty middle.fetch("released_findings")
    refute middle.fetch("rights_column_present")
    refute_includes middle.fetch("tables"), "kobo_account_book_files"
    assert facts.dig("resumed", "verified")
    assert_equal 5, facts.dig("resumed", "applied")
  end

  def test_a_killed_process_leaves_a_consistent_database_that_resumes
    facts = drive("kill")
    assert facts.fetch("signaled")
    assert_equal 9, facts.fetch("signal")
    middle = facts.fetch("middle")
    assert_equal "20261110120000", middle.fetch("highest_version")
    assert_empty middle.fetch("released_findings")
    refute_includes middle.fetch("tables"), "kobo_tags"
    assert_includes middle.fetch("tables"), "kobo_kepub_copies"
    assert facts.dig("resumed", "verified")
    assert_equal 1, facts.dig("resumed", "applied")
  end

  def test_a_migration_that_never_returns_is_stopped_at_the_deadline_and_the_upgrade_resumes
    facts = drive("hang")
    assert facts.fetch("signaled")
    assert_equal 9, facts.fetch("signal")
    assert_equal "upgrade failed: migration: deadline of 3 seconds exceeded; the database is left for SQLite to recover", facts.fetch("stderr")
    middle = facts.fetch("middle")
    assert_equal "20261110120000", middle.fetch("highest_version")
    assert_empty middle.fetch("released_findings")
    refute_includes middle.fetch("tables"), "kobo_tags"
    assert facts.dig("resumed", "verified")
    assert_equal 1, facts.dig("resumed", "applied")
  end

  def test_a_final_migration_that_returns_after_the_deadline_is_a_failure
    failure = drive("late-final-migration").fetch("failure")
    assert_equal "migration", failure.fetch("stage")
    assert_match(/deadline of 100 seconds exceeded/, failure.fetch("message"))
    assert_equal [ "1" ], failure.fetch("applied")
  end

  def test_a_migration_inside_its_budget_is_never_killed_near_a_second_boundary_and_bad_budgets_are_refused
    facts = drive("budget-near-a-second-boundary")
    assert_equal [ "1" ], facts.fetch("applied")
    assert_equal [ "migration: the deadline must be a finite number of seconds" ] * 3, facts.fetch("refused")
  end

  def test_the_watchdog_receives_the_budget_at_full_precision
    assert_equal %w[0.5 0.5 120 33.3333333 1.20892582e+24], drive("watchdog-arguments").fetch("budgets")
  end

  def test_a_fractional_budget_kills_a_blocked_migration_long_before_the_whole_second_above_it
    facts = drive("fractional-budget-overrun")
    assert_equal 9, facts.fetch("signal")
    assert_operator facts.fetch("seconds"), :>=, 0.5
    assert_operator facts.fetch("seconds"), :<, 10
  end

  def test_an_exhausted_deadline_stops_before_any_migration_and_leaves_the_released_database_untouched
    facts = drive("deadline")
    failure = facts.fetch("failure")
    assert_equal "migration", failure.fetch("stage")
    assert_match(/deadline of -1 seconds exceeded/, failure.fetch("message"))
    assert_empty failure.fetch("applied")
    middle = facts.fetch("middle")
    assert_equal RELEASED_VERSION, middle.fetch("highest_version")
    assert_equal facts.dig("resumed", "before_digest"), middle.fetch("digest")
    assert facts.dig("resumed", "verified")
  end

  def test_a_database_with_no_optional_state_upgrades
    facts = drive("sparse")
    assert facts.fetch("verified")
    assert_equal 17, facts.fetch("applied")
  end

  def test_loading_the_current_schema_over_the_released_data_is_rejected
    failure = drive("reload-current-schema").fetch("failure")
    assert_equal "verification", failure.fetch("stage")
    assert_match(/row-lost:/, failure.fetch("message"))
  end

  def test_skipping_the_migrations_is_rejected
    failure = drive("skip-migrations").fetch("failure")
    assert_equal "migration", failure.fetch("stage")
    assert_match(/still pending/, failure.fetch("message"))
  end

  VARIANTS = {
    "untouched" => [ [], nil ],
    "changed-value" => [ [ "UPDATE users SET name = 'Changed' WHERE id = 11" ], "value-changed:users:[11]:name" ],
    "changed-type" => [ [ "UPDATE users SET name = CAST(name AS BLOB) WHERE id = 7" ], "value-changed:users:[7]:name" ],
    "swapped-password-digest" => [ [ "UPDATE users SET password_digest = (SELECT password_digest FROM users WHERE id = 7) WHERE id = 11" ], "value-changed:users:[11]:password_digest" ],
    "truncated-ciphertext" => [ [ "UPDATE users SET otp_secret = substr(otp_secret, 1, 40) WHERE id = 11" ], "value-changed:users:[11]:otp_secret" ],
    "changed-setting" => [ [ "UPDATE settings SET value = 'changed' WHERE key = 'prowlarr_api_key'" ], "value-changed:settings:[4]:value" ],
    "lost-row" => [ [ "DELETE FROM books WHERE id = 5" ], "row-lost:books:[5]" ],
    "extra-row" => [ [ "INSERT INTO books (title, book_type, created_at, updated_at) VALUES ('extra', 1, 't', 't')" ], "rows-added:books:1" ],
    "reset-sequence" => [ [ "UPDATE sqlite_sequence SET seq = 1 WHERE name = 'books'" ], "sequence-changed:books" ],
    "dropped-column" => [ [ "ALTER TABLE users DROP COLUMN backup_codes" ], "column-changed:users.backup_codes" ],
    "dropped-index" => [ [ "DROP INDEX index_users_on_role" ], "index-changed:users.index_users_on_role" ],
    "populated-new-column" => [ [ "UPDATE api_tokens SET issued_via = 'consumer_device' WHERE id = 4" ], "added-column-not-null:api_tokens:[4]:issued_via" ],
    "populated-new-table" => [ [ "INSERT INTO consumer_reading_states (user_id, book_id, created_at, updated_at) VALUES (11, 5, 't', 't')" ], "new-table-not-empty:consumer_reading_states" ],
    "lost-new-table" => [ [ "DROP TABLE kobo_tags" ], "table-lost:kobo_tags" ],
    "missing-current-version" => [ [ "DELETE FROM schema_migrations WHERE version = '#{CURRENT_VERSION}'" ], "versions-after-differ-from-checkout" ],
    "lost-released-version" => [ [ "DELETE FROM schema_migrations WHERE version = '#{RELEASED_VERSION}'" ], "release-versions-lost" ]
  }.freeze

  def test_tampering_with_the_upgraded_database_is_named_by_the_verifier
    facts = drive("variants", JSON.generate(VARIANTS.transform_values(&:first)))
    VARIANTS.each do |name, (_, expected)|
      findings = facts.fetch(name)
      expected.nil? ? assert_empty(findings, name) : assert_includes(findings, expected, name)
    end
  end

  def produce_bundle
    out = File.join(@scratch, "bundle")
    output, status = Open3.capture2e(environment, "bundle", "exec", "ruby", PRODUCER, "--out", out, "--mode", "stable-upgrade", chdir: REPO, unsetenv_others: true)
    assert status.success?, output
    out
  end

  def rows(path, sql)
    database = SQLite3::Database.new("file:#{path}?mode=ro&immutable=1", flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
    database.execute(sql)
  ensure
    database&.close
  end

  def test_the_bundle_records_released_data_that_survived_and_new_data_added_afterwards
    out = produce_bundle
    manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
    evidence = JSON.parse(File.read(File.join(out, "expected", "stable-upgrade.json")))
    source = File.join(out, "db", "released-source.sqlite3")
    upgraded = File.join(out, "db", "primary.sqlite3")

    assert_equal "stable-upgrade", manifest.fetch("origin")
    assert_equal CURRENT_VERSION, manifest.dig("schema", "revision")
    assert_equal "partial", manifest.dig("coverage", "gaps").find { |gap| gap["id"] == "stable-volume-upgrade" }.fetch("status")
    assert_includes manifest.fetch("files"), "expected/stable-upgrade.json"
    assert_includes manifest.fetch("files"), "db/released-source.sqlite3"
    assert_equal evidence.dig("source", "sha256"), manifest.dig("files", "db/released-source.sqlite3", "sha256")
    assert_equal 0o440, File.stat(source).mode & 0o777
    assert_empty Dir.glob("#{out}/db/*-{wal,shm,journal}")

    assert_equal PINNED_COMMIT, evidence.dig("release", "commit")
    assert_equal RELEASED_VERSION, evidence.dig("schema", "before_revision")
    assert_equal 17, evidence.fetch("migrations_applied").size

    released_tables = rows(source, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").flatten
    assert_equal 30, released_tables.size
    assert_empty released_tables & NEW_TABLES
    assert_equal [ [ 100, RELEASED_VERSION ] ], rows(source, "SELECT COUNT(*), MAX(version) FROM schema_migrations")
    assert_equal [ [ 117, CURRENT_VERSION ] ], rows(upgraded, "SELECT COUNT(*), MAX(version) FROM schema_migrations")
    assert_equal NEW_TABLES, rows(upgraded, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (#{NEW_TABLES.map { |name| "'#{name}'" }.join(', ')}) ORDER BY name").flatten

    released_tables.reject { |name| name == "schema_migrations" }.each do |name|
      refute_empty rows(source, "SELECT 1 FROM #{name} LIMIT 1"), "#{name} has no released record"
      assert_equal evidence.dig("preserved", name, "rows"), evidence.dig("preserved", name, "preserved"), name
    end

    assert_equal rows(source, "SELECT id, username, password_digest, otp_secret, backup_codes, role, deleted_at, created_at, updated_at FROM users ORDER BY id"),
      rows(upgraded, "SELECT id, username, password_digest, otp_secret, backup_codes, role, deleted_at, created_at, updated_at FROM users ORDER BY id")
    assert_equal rows(source, "SELECT id, password, api_key FROM download_clients ORDER BY id"), rows(upgraded, "SELECT id, password, api_key FROM download_clients ORDER BY id")
    assert_equal rows(source, "SELECT id, key, value, value_type FROM settings ORDER BY id"), rows(upgraded, "SELECT id, key, value, value_type FROM settings ORDER BY id")
    assert_equal rows(source, "SELECT id, file_path, book_type, content_kind, created_at FROM books ORDER BY id"), rows(upgraded, "SELECT id, file_path, book_type, content_kind, created_at FROM books ORDER BY id")
    assert_equal rows(source, "SELECT id, direct_output_root_device, direct_output_root_inode, size_bytes, status FROM downloads ORDER BY id"),
      rows(upgraded, "SELECT id, direct_output_root_device, direct_output_root_inode, size_bytes, status FROM downloads ORDER BY id")

    legacy = rows(source, "SELECT id FROM api_tokens ORDER BY id").flatten
    assert_equal legacy, rows(upgraded, "SELECT id FROM api_tokens WHERE id IN (#{legacy.join(', ')}) AND issued_via IS NULL AND replaces_api_token_id IS NULL AND connection_key IS NULL ORDER BY id").flatten

    assert_equal %w[api_tokens consumer_progresses consumer_reading_states], evidence.dig("post_upgrade", "rows_added").keys.sort
    changed = evidence.dig("post_upgrade", "preserved_rows_changed")
    assert_equal [ "api_tokens" ], changed.map { |change| change.fetch("table") }.uniq
    assert_equal [ %w[last_used_at updated_at] ], changed.map { |change| change.fetch("columns") }.uniq
  end

  def test_released_data_keeps_the_missing_optional_state_it_had
    out = produce_bundle
    source = File.join(out, "db", "released-source.sqlite3")
    assert_operator rows(source, "SELECT COUNT(*) FROM users WHERE otp_secret IS NULL AND backup_codes IS NULL").first.first, :>=, 2
    assert_equal [ [ nil, nil ] ], rows(source, "SELECT password, api_key FROM download_clients WHERE id = 9")
    assert_operator rows(source, "SELECT COUNT(*) FROM books WHERE file_path IS NULL OR TRIM(file_path) = ''").first.first, :>=, 2
    assert_equal [ [ nil, "" ] ], rows(source, "SELECT (SELECT value FROM settings WHERE key = 'indexer_provider'), (SELECT value FROM settings WHERE key = 'jackett_url')")
  end
end
