# frozen_string_literal: true

require_relative "support/volume_test_case"
require "digest"
require_relative "support/synthetic_volume"

module Migration
  module Volume
    class BackupTest < VolumeTestCase
      def guard = VolumeGuard.new(docker: docker)
      def backup = VolumeBackup.new(docker: docker)

      def snapshot_directory(volume, name = "snapshot-#{SecureRandom.hex(3)}")
        File.join(volume.directory, name)
      end

      def test_snapshot_and_restore_round_trip_a_stopped_volume_including_root_owned_keys
        volume, before = seeded("beta")
        directory = snapshot_directory(volume)
        manifest = backup.snapshot(storage: volume.storage, out: directory)
        assert_equal Layout::DATABASES.sort, manifest.fetch("databases").keys.sort
        assert_equal Layout::KEY_FILES.sort, manifest.fetch("key_files_present").sort
        refute_includes File.read(File.join(directory, "snapshot.json")), "ACTIVE_RECORD_ENCRYPTION"
        assert_clean Comparison.call(before, harness.capture(volume), allowances: Contracts.strict), "taking the snapshot changed the volume"
        target = File.join(volume.directory, "restored")
        FileUtils.mkdir_p(target)
        backup.restore(snapshot: directory, target: target)
        volume.storage = target
        restored = harness.capture(volume)
        assert_same_content(before, restored)
        assert_equal [ 0, 0 ], restored.files.fetch(Layout::ENCRYPTION_KEYS).to_h.values_at(:uid, :gid)
        assert_equal 0o600, restored.files.fetch(Layout::ENCRYPTION_KEYS).mode
        container = harness.boot(volume, "beta")
        assert_alive(container, volume)
        harness.stop(container)
      end

      def test_a_primary_only_volume_round_trips_without_creating_secondary_databases
        volume = SyntheticVolume.new(File.join(harness.scratch, "primary-only")).build
        [ Layout::QUEUE, Layout::CABLE, Layout::CACHE ].each { |name| FileUtils.rm(File.join(volume.storage, name)) }
        before = volume.capture(harness.scratch)
        directory = File.join(volume.root, "snapshot")
        manifest = backup.snapshot(storage: volume.storage, out: directory)
        assert_equal [ Layout::PRIMARY ], manifest.fetch("databases").keys
        target = File.join(volume.root, "restored")
        Dir.mkdir(target)
        backup.restore(snapshot: directory, target: target)
        restored = VolumeState.capture(storage: target, scratch: harness.scratch)
        assert_equal before.databases.fetch(Layout::PRIMARY).digest, restored.databases.fetch(Layout::PRIMARY).digest
        [ Layout::QUEUE, Layout::CABLE, Layout::CACHE ].each { |name| assert_nil restored.databases.fetch(name) }
        Layout::KEY_FILES.each { |name| assert_equal before.files.fetch(name).digest, restored.files.fetch(name).digest }
      end

      def test_a_running_volume_is_never_snapshotted
        volume, = seeded("beta")
        container = harness.boot(volume, "beta")
        directory = snapshot_directory(volume)
        error = assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: directory) }
        assert_match(/active/, error.message)
        refute File.exist?(directory), "a refused snapshot must leave nothing behind"
        docker.stop(container)
        assert backup.snapshot(storage: volume.storage, out: directory)
        docker.remove(container)
      end

      def test_a_paused_container_also_counts_as_active
        volume, = seeded("beta")
        container = harness.boot(volume, "beta")
        Command.run!("docker", "pause", container)
        assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
        Command.run!("docker", "unpause", container)
        harness.stop(container)
      end

      def test_ambiguous_paths_and_missing_keys_are_refused
        volume, = seeded("beta")
        link = File.join(volume.directory, "storage-link")
        File.symlink(volume.storage, link)
        assert_raises(Refusal) { backup.snapshot(storage: link, out: snapshot_directory(volume)) }
        assert_raises(Refusal) { backup.snapshot(storage: "relative/storage", out: snapshot_directory(volume)) }
        assert_raises(Refusal) { backup.snapshot(storage: File.join(volume.directory, "absent"), out: snapshot_directory(volume)) }
        assert_raises(Refusal) { backup.snapshot(storage: volume.directory, out: snapshot_directory(volume)) }
        inside = File.join(volume.storage, "backup-inside")
        assert_raises(BackupRefused) { backup.snapshot(storage: volume.storage, out: inside) }
        existing = snapshot_directory(volume)
        FileUtils.mkdir_p(existing)
        assert_raises(BackupRefused) { backup.snapshot(storage: volume.storage, out: existing) }
        docker.helper(volumes: [ [ volume.storage, "/volume", "rw" ] ], script: "rm -f /volume/#{Layout::ENCRYPTION_KEYS}")
        error = assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
        assert_match(/key material is missing/, error.message)
        assert backup.snapshot(storage: volume.storage, out: snapshot_directory(volume), environment_keys: true), "operator-declared environment keys are accepted"
      end

      def test_a_hot_rollback_journal_is_refused
        volume, = seeded("beta")
        File.write(File.join(volume.storage, "production_cache.sqlite3-journal"), "x")
        error = assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
        assert_match(/hot rollback journal/, error.message)
      end

      def test_a_process_holding_a_volume_file_open_is_refused
        volume, = seeded("beta")
        File.open(File.join(volume.storage, Layout::PRIMARY), "rb") do
          error = assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
          assert_match(/hold files of the volume open/, error.message)
        end
      end

      def test_a_corrupt_database_is_refused_not_snapshotted
        volume, = seeded("beta")
        path = File.join(volume.storage, Layout::QUEUE)
        File.open(path, "r+b") { |file| file.seek(4096 * 2); file.write("\x00" * 4096) }
        directory = snapshot_directory(volume)
        error = assert_raises(StandardError) { backup.snapshot(storage: volume.storage, out: directory) }
        assert_match(/integrity|malformed|not a database|corrupt/i, error.message)
        refute File.exist?(directory)
      end

      def test_the_snapshot_of_a_crashed_volume_contains_the_write_ahead_log_contents_and_a_naive_file_copy_does_not
        volume, = seeded("beta")
        container = harness.boot(volume, "beta")
        docker.rails_runner(container, "10.times { |index| Setting.create!(key: \"m2_crash_\#{index}\", value: \"v\", value_type: \"string\", category: \"general\") }")
        harness.crash(container)
        crashed = harness.capture(volume)
        assert_operator crashed.wal_bytes.fetch(Layout::PRIMARY).to_i, :>, 0
        crash_rows = ->(state) { state.databases.fetch(Layout::PRIMARY).tables.fetch("settings").rows.values.count { |row| row.fetch("key").last.start_with?("m2_crash_") } }
        assert_equal 10, crash_rows.call(crashed)

        naive = File.join(volume.directory, "naive-copy")
        FileUtils.mkdir_p(naive)
        FileUtils.cp(File.join(volume.storage, Layout::PRIMARY), naive)
        naive_state = SafeCopy.open(naive, Layout::PRIMARY, scratch: harness.scratch) { |database| database.execute("SELECT COUNT(*) FROM settings WHERE key LIKE 'm2_crash_%'").first.first }
        assert_equal 0, naive_state, "copying the database file without its write-ahead log loses committed writes"

        directory = snapshot_directory(volume)
        backup.snapshot(storage: volume.storage, out: directory)
        target = File.join(volume.directory, "crash-restored")
        FileUtils.mkdir_p(target)
        backup.restore(snapshot: directory, target: target)
        volume.storage = target
        restored = harness.capture(volume)
        assert_equal 10, crash_rows.call(restored)
        assert_same_content(crashed, restored)
      end

      def test_restore_refuses_a_populated_target_a_tampered_snapshot_and_an_incomplete_one
        volume, = seeded("beta")
        directory = snapshot_directory(volume)
        backup.snapshot(storage: volume.storage, out: directory)
        occupied = File.join(volume.directory, "occupied")
        FileUtils.mkdir_p(occupied)
        File.write(File.join(occupied, "leftover"), "x")
        assert_raises(Refusal) { backup.restore(snapshot: directory, target: occupied) }
        assert_equal [ "leftover" ], Dir.children(occupied)
        assert_raises(Refusal) { backup.restore(snapshot: directory, target: File.join(volume.directory, "absent")) }

        tampered = File.join(volume.directory, "tampered")
        FileUtils.cp_r(directory, tampered)
        File.open(File.join(tampered, "databases", Layout::PRIMARY), "r+b") { |file| file.seek(200); file.write("\x7f") }
        fresh = File.join(volume.directory, "fresh-1")
        FileUtils.mkdir_p(fresh)
        assert_raises(BackupRefused) { backup.restore(snapshot: tampered, target: fresh) }
        assert_empty Dir.children(fresh), "a refused restore must not write anything"

        archive_tampered = File.join(volume.directory, "archive-tampered")
        FileUtils.cp_r(directory, archive_tampered)
        File.open(File.join(archive_tampered, "files.tar"), "ab") { |file| file.write("x") }
        fresh = File.join(volume.directory, "fresh-2")
        FileUtils.mkdir_p(fresh)
        assert_raises(BackupRefused) { backup.restore(snapshot: archive_tampered, target: fresh) }

        incomplete = File.join(volume.directory, "incomplete")
        FileUtils.cp_r(directory, incomplete)
        FileUtils.rm(File.join(incomplete, "snapshot.json"))
        fresh = File.join(volume.directory, "fresh-3")
        FileUtils.mkdir_p(fresh)
        error = assert_raises(BackupRefused) { backup.restore(snapshot: incomplete, target: fresh) }
        assert_match(/incomplete/, error.message)
      end

      def test_a_manifest_naming_a_database_outside_the_contract_is_refused_before_anything_is_written
        volume, = seeded("beta")
        directory = snapshot_directory(volume)
        backup.snapshot(storage: volume.storage, out: directory)
        crafted = File.join(volume.directory, "crafted")
        FileUtils.cp_r(directory, crafted)
        hostile = "x; touch injected; #"
        File.binwrite(File.join(crafted, "databases", hostile), "hostile")
        manifest = JSON.parse(File.read(File.join(crafted, "snapshot.json")))
        manifest["databases"][hostile] = manifest.fetch("databases").fetch(Layout::PRIMARY).merge("sha256" => Digest::SHA256.hexdigest("hostile"))
        File.write(File.join(crafted, "snapshot.json"), JSON.generate(manifest))
        target = File.join(volume.directory, "never-written")
        FileUtils.mkdir_p(target)
        error = assert_raises(BackupRefused) { backup.restore(snapshot: crafted, target: target) }
        assert_match(/outside the volume contract/, error.message)
        assert_empty Dir.children(target)
      end

      def test_a_symbolic_link_in_place_of_a_database_or_sidecar_is_refused
        volume, = seeded("beta")
        outside = File.join(volume.directory, "elsewhere.sqlite3")
        FileUtils.cp(File.join(volume.storage, Layout::CACHE), outside)
        FileUtils.rm(File.join(volume.storage, Layout::CACHE))
        File.symlink(outside, File.join(volume.storage, Layout::CACHE))
        error = assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
        assert_match(/symbolic link/, error.message)
        assert_raises(UnsafeSource) { SafeCopy.open(volume.storage, Layout::CACHE, scratch: harness.scratch) { |_| nil } }
        FileUtils.rm(File.join(volume.storage, Layout::CACHE))
        FileUtils.cp(outside, File.join(volume.storage, Layout::CACHE))
        File.symlink(outside, File.join(volume.storage, "#{Layout::CACHE}-wal"))
        assert_raises(Refusal) { backup.snapshot(storage: volume.storage, out: snapshot_directory(volume)) }
      end

      def test_restore_refuses_a_target_mounted_by_an_active_container
        volume, = seeded("beta")
        directory = snapshot_directory(volume)
        backup.snapshot(storage: volume.storage, out: directory)
        target = File.join(volume.directory, "mounted-empty")
        FileUtils.mkdir_p(target)
        helper = docker.start(image: Docker::HELPER_IMAGE, role: "holder", storage: target, entrypoint: "sleep", command: [ "300" ])
        assert_raises(Refusal) { backup.restore(snapshot: directory, target: target) }
        docker.remove(helper)
      end
    end
  end
end
