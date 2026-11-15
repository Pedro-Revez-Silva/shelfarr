# frozen_string_literal: true

require_relative "support/volume_test_case"

module Migration
  module Volume
    class UpgradeTest < VolumeTestCase
      ROOT = File.expand_path("../../../..", __dir__)

      def candidate_versions
        Dir[File.join(ROOT, "db/migrate/*.rb")].map { |path| File.basename(path)[/\A\d+/] }.sort
      end

      def applied_versions(state)
        state.databases.fetch(Layout::PRIMARY).tables.fetch("schema_migrations").rows.values.map { |row| row.fetch("version").last }.sort
      end

      def test_stable_volume_upgrades_through_the_production_entrypoint
        volume, before = seeded("stable")
        assert_equal 100, applied_versions(before).size
        container = harness.boot(volume, "candidate")
        assert docker.logged?(container, "Using existing auto-generated secret key"), "the entrypoint did not reuse the secret key"
        assert docker.logged?(container, "Using existing auto-generated encryption keys"), "the entrypoint did not reuse the encryption keys"
        refute docker.logged?(container, "Generated new"), "the entrypoint generated a key over an existing volume"
        outcome = assert_alive(container, volume)
        assert_equal candidate_versions.last.to_i, outcome["schema"]
        harness.stop(container)
        after = harness.capture(volume)
        assert_clean Comparison.call(before, after, allowances: Contracts.upgrade.merge(new_tables_empty: true))
        assert_equal candidate_versions, applied_versions(after)
        assert_equal 17, (applied_versions(after) - applied_versions(before)).size
        assert_equal Layout::DATABASES.sort, after.files.keys.grep(/\Aproduction[a-z_]*\.sqlite3\z/).sort
      end

      def test_beta_predecessor_volume_starts_on_the_candidate_without_changes
        volume, before = seeded("beta")
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        after = harness.capture(volume)
        assert_clean Comparison.call(before, after, allowances: Contracts.same_schema)
        assert_equal applied_versions(before), applied_versions(after)
      end

      def test_repeat_startup_changes_nothing_and_never_regenerates_keys
        volume, = seeded("stable")
        first = harness.boot(volume, "candidate")
        harness.stop(first)
        upgraded = harness.capture(volume)
        second = harness.boot(volume, "candidate")
        refute docker.logged?(second, "Generated new"), "the second start generated a key"
        assert_alive(second, volume)
        harness.stop(second)
        assert_clean Comparison.call(upgraded, harness.capture(volume), allowances: Contracts.same_schema)
      end

      def test_environment_provided_keys_are_not_written_to_the_volume
        volume, before = seeded("stable", key_mode: :environment)
        assert_empty before.files.keys & Layout::KEY_FILES
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        after = harness.capture(volume)
        assert_empty after.files.keys & Layout::KEY_FILES
        assert_clean Comparison.call(before, after, allowances: Contracts.upgrade)
      end

      def test_missing_encryption_keys_are_refused_by_the_guard_and_regenerated_by_the_entrypoint
        volume, before = seeded("stable")
        guard = VolumeGuard.new(docker: docker)
        assert guard.assert_keys_present!(volume.storage)
        hold(volume, Layout::ENCRYPTION_KEYS)
        error = assert_raises(Refusal) { guard.assert_keys_present!(volume.storage) }
        assert_match(/key material is missing/, error.message)
        container = harness.boot(volume, "candidate")
        assert docker.logged?(container, "Generated new encryption keys"), "expected the entrypoint to generate keys"
        failure = assert_raises(CommandFailed) { harness.verify_state!(volume, container) }
        assert_match(/Decryption/, failure.message)
        harness.stop(container)
        release_held(volume, Layout::ENCRYPTION_KEYS, replace: true)
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        assert_clean Comparison.call(before, harness.capture(volume), allowances: Contracts.upgrade)
      end

      def test_missing_secret_key_base_invalidates_sessions_but_not_data_until_restored
        volume, before = seeded("stable")
        hold(volume, Layout::SECRET_KEY_BASE)
        container = harness.boot(volume, "candidate")
        assert docker.logged?(container, "Generated new secret key"), "expected the entrypoint to generate a secret key"
        refute_equal 200, harness.authenticated_status(container, "/requests", volume.secrets.fetch(:cookie))
        harness.stop(container)
        release_held(volume, Layout::SECRET_KEY_BASE, replace: true)
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        assert_clean Comparison.call(before, harness.capture(volume), allowances: Contracts.upgrade)
      end

      def test_sigkill_during_a_long_index_build_leaves_a_consistent_volume_that_resumes
        volume, = seeded("stable")
        harness.add_bulk_books(volume, 600_000)
        before = harness.inspect_primary(volume)
        assert_equal [ "ok" ], before.fetch("integrity")
        container = harness.boot(volume, "candidate", wait: false, cpus: 0.15)
        assert_equal :killed, harness.kill_when_applied(volume, container, count: 103)
        partial = harness.inspect_primary(volume)
        assert_equal [ "ok" ], partial.fetch("integrity")
        assert_includes partial.fetch("versions"), "20261107140000"
        refute_includes partial.fetch("versions"), "20261107141000", "the kill landed after the index build finished"
        refute partial.fetch("index"), "the index must not exist after an interrupted build"
        assert_equal before.fetch("books"), partial.fetch("books")
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        resumed = harness.inspect_primary(volume)
        assert_empty candidate_versions - resumed.fetch("versions")
        assert_empty resumed.fetch("versions") - candidate_versions
        assert resumed.fetch("index"), "the resumed start must finish the index"
        assert_equal before.fetch("books"), resumed.fetch("books")
      end

      def test_a_failed_migration_stops_the_entrypoint_and_the_next_start_resumes
        volume, before = seeded("stable")
        database = SQLite3::Database.new(File.join(volume.storage, Layout::PRIMARY))
        database.execute("CREATE TABLE kobo_account_shares (id INTEGER PRIMARY KEY)")
        database.close
        container = harness.boot(volume, "candidate", wait: false)
        assert_operator docker.wait_exit(container), :>, 0, "the entrypoint must stop when a migration fails"
        harness.stop(container)
        failed = harness.capture(volume)
        refute_includes applied_versions(failed), "20261109020000"
        assert_includes applied_versions(failed), "20261109010000"
        database = SQLite3::Database.new(File.join(volume.storage, Layout::PRIMARY))
        database.execute("DROP TABLE kobo_account_shares")
        database.close
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        after = harness.capture(volume)
        assert_equal candidate_versions, applied_versions(after)
        assert_clean Comparison.call(before, after, allowances: Contracts.upgrade.merge(new_tables_empty: true))
      end

      def test_crash_with_a_write_ahead_log_is_recovered_by_the_next_start
        volume, = seeded("beta")
        container = harness.boot(volume, "candidate")
        source = "20.times { |index| Setting.create!(key: \"m2_wal_\#{index}\", value: \"v\#{index}\", value_type: \"string\", category: \"general\") }"
        docker.rails_runner(container, source)
        harness.crash(container)
        crashed = harness.capture(volume)
        assert_operator crashed.wal_bytes.fetch(Layout::PRIMARY).to_i, :>, 0, "the crash left no write-ahead log to recover"
        assert_equal 20, crashed.databases.fetch(Layout::PRIMARY).tables.fetch("settings").rows.values.count { |row| row.fetch("key").last.start_with?("m2_wal_") }
        container = harness.boot(volume, "candidate")
        assert_alive(container, volume)
        harness.stop(container)
        recovered = harness.capture(volume)
        assert_clean Comparison.call(crashed, recovered, allowances: Contracts.same_schema)
      end

      def test_capturing_a_stopped_volume_does_not_modify_it
        volume, first = seeded("beta")
        second = harness.capture(volume)
        assert_clean Comparison.call(first, second, allowances: Contracts.strict)
        assert_equal first.files.transform_values(&:ctime_ns), second.files.transform_values(&:ctime_ns)
      end

      private

      def hold(volume, name)
        result = docker.helper(volumes: [ [ volume.storage, "/volume", "rw" ] ], script: "mv /volume/#{name} /volume/#{name}.m2-held")
        assert result.success?, "could not set the key file aside"
      end

      def release_held(volume, name, replace:)
        script = replace ? "rm -f /volume/#{name} && mv /volume/#{name}.m2-held /volume/#{name}" : "mv /volume/#{name}.m2-held /volume/#{name}"
        assert docker.helper(volumes: [ [ volume.storage, "/volume", "rw" ] ], script: script).success?, "could not restore the key file"
      end
    end
  end
end
