# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "support/synthetic_volume"
require_relative "../lib/comparison"
require_relative "../lib/contracts"
require_relative "../lib/scratch"

module Migration
  module Volume
    class ComparisonTest < Minitest::Test
      def setup
        @scratch = Dir.mktmpdir("m2-comparison-", Scratch.root)
        @volume = SyntheticVolume.new(File.join(@scratch, "a")).build
        @before = @volume.capture(@scratch)
      end

      def teardown
        FileUtils.rm_rf(@scratch)
      end

      def mutate(allowances: Contracts.strict)
        copy = @volume.copy_to(File.join(@scratch, "b-#{SecureRandom.hex(3)}"))
        baseline = copy.capture(@scratch)
        yield copy
        Comparison.call(baseline, copy.capture(@scratch), allowances: allowances).map(&:to_s)
      end

      def test_capturing_twice_without_a_change_reports_nothing
        assert_empty Comparison.call(@before, @volume.capture(@scratch), allowances: Contracts.strict)
        assert_empty mutate { |_| nil }
      end

      def test_a_changed_value_is_named_by_table_row_and_column_only
        found = mutate { |copy| copy.primary { |database| database.execute("UPDATE users SET password_digest = 'tampered-digest' WHERE id = 1") } }
        assert_includes found, "production.sqlite3:users[[1]].password_digest:value-changed"
        refute_includes found.join, "tampered-digest"
      end

      def test_a_lost_row_a_lost_table_a_lost_column_and_a_lost_index_are_reported
        found = mutate do |copy|
          copy.primary do |database|
            database.execute("DELETE FROM users WHERE id = 2")
            database.execute("DROP TABLE notes")
            database.execute("DROP INDEX index_users_on_name")
            database.execute("ALTER TABLE users DROP COLUMN last_seen_at")
          end
        end
        %w[production.sqlite3:users[[2]]:row-lost production.sqlite3:notes:table-lost production.sqlite3:users#index_users_on_name:index-lost production.sqlite3:users.last_seen_at:column-lost].each { |line| assert_includes found, line }
      end

      def test_a_dropped_unique_constraint_and_a_changed_collation_are_reported_as_definition_changes
        base = @volume.copy_to(File.join(@scratch, "with-tokens"))
        base.primary do |database|
          database.execute("CREATE TABLE tokens (id INTEGER PRIMARY KEY, value TEXT UNIQUE)")
          database.execute("INSERT INTO tokens VALUES (1, 'a')")
        end
        before = base.capture(@scratch)
        base.primary do |database|
          database.execute("CREATE TABLE tokens_rebuilt (id INTEGER PRIMARY KEY, value TEXT)")
          database.execute("INSERT INTO tokens_rebuilt SELECT * FROM tokens")
          database.execute("DROP TABLE tokens")
          database.execute("ALTER TABLE tokens_rebuilt RENAME TO tokens")
        end
        found = Comparison.call(before, base.capture(@scratch), allowances: Contracts.strict).map(&:to_s)
        assert_includes found, "production.sqlite3:tokens:definition-changed"
      end

      def test_a_table_definition_may_change_only_to_the_one_pinned_text
        pinned = Allowances.none.merge(added_columns: { "users" => [ "locale" ] })
        expected = nil
        found = mutate(allowances: pinned) do |copy|
          copy.primary { |database| database.execute("ALTER TABLE users ADD COLUMN locale varchar") }
          expected = copy.capture(@scratch).databases.fetch(Layout::PRIMARY).tables.fetch("users").definition
        end
        assert_includes found, "production.sqlite3:users:definition-changed"
        accepted = mutate(allowances: pinned.merge(definitions_after: { "users" => expected })) do |copy|
          copy.primary { |database| database.execute("ALTER TABLE users ADD COLUMN locale varchar") }
        end
        assert_empty accepted
        other = mutate(allowances: pinned.merge(definitions_after: { "users" => expected })) do |copy|
          copy.primary do |database|
            database.execute("ALTER TABLE users ADD COLUMN locale varchar")
            database.execute("ALTER TABLE users ADD COLUMN extra TEXT GENERATED ALWAYS AS (name || 'x') VIRTUAL")
          end
        end
        assert_includes other, "production.sqlite3:users:definition-changed"
      end

      def test_a_redefined_index_and_a_redefined_column_are_reported_even_when_names_match
        found = mutate do |copy|
          copy.primary do |database|
            database.execute("DROP INDEX index_users_on_name")
            database.execute("CREATE INDEX index_users_on_name ON users (password_digest)")
            database.execute("CREATE TABLE notes_rebuilt (body INTEGER NOT NULL DEFAULT 0)")
            database.execute("INSERT INTO notes_rebuilt SELECT body FROM notes")
            database.execute("DROP TABLE notes")
            database.execute("ALTER TABLE notes_rebuilt RENAME TO notes")
          end
        end
        assert_includes found, "production.sqlite3:users#index_users_on_name:index-changed"
        assert_includes found, "production.sqlite3:notes:definition-changed"
      end

      def test_a_type_change_is_a_value_change
        found = mutate { |copy| copy.primary { |database| database.execute("UPDATE users SET otp_secret = '' WHERE id = 2") } }
        assert_includes found, "production.sqlite3:users[[2]].otp_secret:value-changed"
      end

      def test_a_reset_autoincrement_counter_is_reported
        found = mutate { |copy| copy.primary { |database| database.execute("UPDATE sqlite_sequence SET seq = 0 WHERE name = 'users'") } }
        assert_includes found, "production.sqlite3:sqlite_sequence.users:counter-reset"
      end

      def test_added_rows_and_tables_are_violations_unless_allowed
        grow = lambda do |copy|
          copy.primary do |database|
            database.execute("INSERT INTO users (name) VALUES ('new')")
            database.execute("CREATE TABLE fresh (id INTEGER)")
            database.execute("INSERT INTO fresh VALUES (1)")
          end
        end
        strict = mutate(&grow)
        assert_includes strict, "production.sqlite3:users[[3]]:row-added"
        assert_includes strict, "production.sqlite3:fresh:table-added"
        permitted = Allowances.none.merge(new_row_tables: [ "users" ], new_tables: true, volatile_files: [])
        assert_empty mutate(allowances: permitted, &grow)
        assert_includes mutate(allowances: permitted.merge(new_tables_empty: true), &grow), "production.sqlite3:fresh:new-table-not-empty"
      end

      def test_mutable_columns_are_the_only_permitted_value_changes
        found = mutate(allowances: Allowances.none.merge(mutable_columns: { "users" => [ "last_seen_at" ] })) do |copy|
          copy.primary { |database| database.execute("UPDATE users SET last_seen_at = '2026-02-02', name = 'renamed' WHERE id = 1") }
        end
        assert_includes found, "production.sqlite3:users[[1]].name:value-changed"
        refute_includes found, "production.sqlite3:users[[1]].last_seen_at:value-changed"
      end

      def test_a_lost_database_file_is_reported
        found = mutate { |copy| FileUtils.rm(File.join(copy.storage, Layout::QUEUE)) }
        assert_includes found, "production_queue.sqlite3:file:database-lost"
      end

      def test_key_files_are_compared_by_content_mode_and_inode
        rewritten = mutate do |copy|
          path = File.join(copy.storage, Layout::ENCRYPTION_KEYS)
          content = File.binread(path)
          File.delete(path)
          File.binwrite(path, content, perm: 0o600)
        end
        assert rewritten.any? { |line| line.start_with?("files:.encryption_keys:changed:") && line.include?("inode") }, rewritten.inspect
        changed = mutate { |copy| File.open(File.join(copy.storage, Layout::SECRET_KEY_BASE), "a") { |file| file.write("x") } }
        assert changed.any? { |line| line.start_with?("files:.secret_key_base:changed:") && line.include?("digest") }
        deleted = mutate { |copy| FileUtils.rm(File.join(copy.storage, Layout::SECRET_KEY_BASE)) }
        assert_includes deleted, "files:.secret_key_base:file-lost"
        chmod = mutate { |copy| File.chmod(0o644, File.join(copy.storage, Layout::SECRET_KEY_BASE)) }
        assert chmod.any? { |line| line.start_with?("files:.secret_key_base:changed:") && line.include?("mode") }
      end

      def test_media_identity_changes_are_reported_even_when_the_bytes_match
        touched = mutate { |copy| File.utime(Time.now, Time.now, File.join(copy.media, "library", "book.epub")) }
        assert touched.any? { |line| line.include?("library/book.epub:changed:") && line.include?("mtime_ns") }
        retargeted = mutate do |copy|
          link = File.join(copy.media, "library", "linked.epub")
          File.delete(link)
          File.symlink("/elsewhere/other.epub", link)
        end
        assert retargeted.any? { |line| line.include?("linked.epub:changed:") && line.include?("target") }
        lost = mutate { |copy| FileUtils.rm(File.join(copy.media, "library", "book.epub")) }
        assert lost.any? { |line| line.end_with?("book.epub:file-lost") }
      end

      def test_runtime_queue_tables_are_ignored_but_jobs_are_not
        found = mutate do |copy|
          copy.queue do |database|
            database.execute("INSERT INTO solid_queue_processes (last_heartbeat_at) VALUES ('now')")
            database.execute("DELETE FROM solid_queue_jobs WHERE id = 2")
            database.execute("DELETE FROM solid_queue_ready_executions WHERE job_id = 2")
          end
        end
        assert_includes found, "production_queue.sqlite3:solid_queue_jobs[[2]]:row-lost"
        assert_includes found, "production_queue.sqlite3:solid_queue_ready_executions[[2]]:row-lost"
        refute(found.any? { |line| line.include?("solid_queue_processes") })
      end

      def test_cable_and_cache_contents_are_disposable_but_the_files_must_open
        found = mutate do |copy|
          copy.open(Layout::CABLE) { |database| database.execute("INSERT INTO entries (value) VALUES ('x')") }
          copy.open(Layout::CACHE) { |database| database.execute("DELETE FROM entries") }
        end
        assert_empty found
        lost = mutate { |copy| FileUtils.rm(File.join(copy.storage, Layout::CACHE)) }
        assert_includes lost, "production_cache.sqlite3:file:database-lost"
      end

      def test_violations_never_carry_values_even_for_tables_without_a_primary_key
        found = mutate { |copy| copy.primary { |database| database.execute("DELETE FROM notes") } }
        assert found.any? { |line| line.start_with?("production.sqlite3:notes[") && line.end_with?(":row-lost") }
        refute_includes found.join, "secret-note-body"
      end
    end
  end
end
