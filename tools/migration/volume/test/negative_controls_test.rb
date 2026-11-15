# frozen_string_literal: true

require_relative "support/volume_test_case"

module Migration
  module Volume
    class NegativeControlsTest < VolumeTestCase
      Mutant = Struct.new(:directory, :storage, :media_roots)

      def self.fixture
        @fixture ||= begin
          test = new("fixture")
          volume, = test.seeded("stable")
          container = Shared.harness.boot(volume, "candidate")
          Shared.harness.record_activity!(volume, container)
          Shared.harness.stop(container)
          volume
        end
      end

      def mutant_copy
        volume = self.class.fixture
        directory = File.join(harness.scratch, "mutant-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(directory)
        result = docker.helper(volumes: [ [ volume.storage, "/source", "ro" ], [ directory, "/target", "rw" ] ], script: "mkdir /target/storage && cp -a /source/. /target/storage/")
        raise "copying the volume failed" unless result.success?
        raise "copying the media failed" unless system("cp", "-a", volume.media.root, File.join(directory, "media"))

        Mutant.new(directory, File.join(directory, "storage"), volume.media.tree_roots.transform_values { |path| File.join(directory, "media", path.delete_prefix("#{volume.media.root}/")) })
      end

      def mutate(allowances: Contracts.strict)
        mutant = mutant_copy
        capture = -> { VolumeState.capture(storage: mutant.storage, media: mutant.media_roots, docker: docker, scratch: harness.scratch) }
        baseline = capture.call
        assert_empty Comparison.call(baseline, capture.call, allowances: Contracts.strict), "the pristine copy must compare clean"
        yield mutant
        Comparison.call(baseline, capture.call, allowances: allowances).map(&:to_s)
      end

      def sql(mutant, name, statement)
        database = SQLite3::Database.new(File.join(mutant.storage, name))
        database.execute("PRAGMA journal_mode = WAL")
        database.execute(statement)
      ensure
        database&.close
      end

      def as_root(mutant, script)
        result = docker.helper(volumes: [ [ mutant.storage, "/volume", "rw" ] ], script: script)
        assert result.success?, "helper failed"
      end

      def test_an_omitted_database_is_reported
        found = mutate { |mutant| FileUtils.rm(File.join(mutant.storage, Layout::QUEUE)) }
        assert_equal [ "production_queue.sqlite3:file:database-lost" ], found
      end

      def test_an_omitted_primary_database_is_reported
        found = mutate { |mutant| FileUtils.rm(File.join(mutant.storage, Layout::PRIMARY)) }
        assert_equal [ "production.sqlite3:file:database-lost" ], found
      end

      def test_a_mutated_password_digest_is_reported
        found = mutate { |mutant| sql(mutant, Layout::PRIMARY, "UPDATE users SET password_digest = password_digest || 'x' WHERE id = 1") }
        assert_equal [ "production.sqlite3:users[[1]].password_digest:value-changed" ], found
      end

      def test_a_mutated_ciphertext_is_reported
        found = mutate { |mutant| sql(mutant, Layout::PRIMARY, "UPDATE download_clients SET api_key = substr(api_key, 1, length(api_key) - 2) || 'zz' WHERE id = 1") }
        assert_equal [ "production.sqlite3:download_clients[[1]].api_key:value-changed" ], found
      end

      def test_a_reset_activity_time_and_a_rewound_version_are_reported
        found = mutate { |mutant| sql(mutant, Layout::PRIMARY, "UPDATE consumer_progresses SET observed_at = '2026-01-01 00:00:00.000000', version = 1") }
        assert_equal [ "production.sqlite3:consumer_progresses[[1]].observed_at:value-changed", "production.sqlite3:consumer_progresses[[1]].version:value-changed" ], found.sort
      end

      def test_a_lost_progress_row_is_reported
        found = mutate { |mutant| sql(mutant, Layout::PRIMARY, "DELETE FROM consumer_progresses") }
        assert_equal [ "production.sqlite3:consumer_progresses[[1]]:row-lost" ], found
      end

      def test_a_dropped_queued_job_is_reported_for_the_job_and_its_execution
        found = mutate do |mutant|
          sql(mutant, Layout::QUEUE, "DELETE FROM solid_queue_ready_executions WHERE job_id IN (SELECT id FROM solid_queue_jobs WHERE class_name = 'Vendor::UnportedJob')")
          sql(mutant, Layout::QUEUE, "DELETE FROM solid_queue_jobs WHERE class_name = 'Vendor::UnportedJob'")
        end
        assert_equal 2, found.size
        assert found.all? { |line| line.end_with?(":row-lost") }, found.inspect
        assert_includes found.map { |line| line.split(":").first(2).join(":") }, "production_queue.sqlite3:solid_queue_jobs[[4]]"
      end

      def test_a_changed_queued_job_class_is_reported
        found = mutate { |mutant| sql(mutant, Layout::QUEUE, "UPDATE solid_queue_jobs SET class_name = 'Renamed' WHERE class_name = 'Vendor::UnportedJob'") }
        assert_equal [ "production_queue.sqlite3:solid_queue_jobs[[4]].class_name:value-changed" ], found
      end

      def test_a_reset_row_counter_is_reported
        found = mutate { |mutant| sql(mutant, Layout::PRIMARY, "UPDATE sqlite_sequence SET seq = 0 WHERE name = 'users'") }
        assert_equal [ "production.sqlite3:sqlite_sequence.users:counter-reset" ], found
      end

      def test_a_changed_key_a_deleted_key_and_an_identically_rewritten_key_are_reported
        changed = mutate { |mutant| as_root(mutant, "echo x >> /volume/#{Layout::ENCRYPTION_KEYS}") }
        assert_equal [ "files:.encryption_keys:changed:size,mtime_ns,digest" ], changed
        deleted = mutate { |mutant| as_root(mutant, "rm /volume/#{Layout::SECRET_KEY_BASE}") }
        assert_equal [ "files:.secret_key_base:file-lost" ], deleted
        rewritten = mutate { |mutant| as_root(mutant, "cp -p /volume/#{Layout::ENCRYPTION_KEYS} /volume/tmp && mv /volume/tmp /volume/#{Layout::ENCRYPTION_KEYS}") }
        assert_equal [ "files:.encryption_keys:changed:inode" ], rewritten
        released = mutate { |mutant| as_root(mutant, "chmod 0644 /volume/#{Layout::ENCRYPTION_KEYS}") }
        assert_equal [ "files:.encryption_keys:changed:mode" ], released
      end

      def test_regenerated_key_files_are_reported
        found = mutate { |mutant| as_root(mutant, "rm /volume/#{Layout::ENCRYPTION_KEYS} /volume/#{Layout::SECRET_KEY_BASE} && echo new > /volume/#{Layout::SECRET_KEY_BASE} && echo new > /volume/#{Layout::ENCRYPTION_KEYS}") }
        assert_equal [ "files:.encryption_keys:changed:mode,size,mtime_ns,inode,digest", "files:.secret_key_base:changed:mode,size,mtime_ns,inode,digest" ], found.sort
      end

      def test_touching_reference_imported_media_is_reported_by_mtime_and_ctime
        found = mutate do |mutant|
          file = mutant.media_roots.fetch("/references") + "/ref-target/Imported Elsewhere.epub"
          File.utime(Time.now, Time.now, file)
        end
        assert_equal [ "media:/references:ref-target/Imported Elsewhere.epub:changed:mtime_ns,ctime_ns" ], found
      end

      def test_replacing_media_with_a_byte_identical_copy_is_reported_by_inode
        found = mutate do |mutant|
          file = mutant.media_roots.fetch("/ebooks") + "/Bea Writer/Quiet Library.epub"
          File.write("#{file}.copy", File.binread(file))
          File.utime(File.mtime(file), File.mtime(file), "#{file}.copy")
          File.rename("#{file}.copy", file)
        end
        assert found.any? { |line| line.include?("Quiet Library.epub:changed:") && line.include?("inode") }, found.inspect
      end

      def test_retargeting_a_reference_symlink_is_reported
        found = mutate do |mutant|
          link = mutant.media_roots.fetch("/ebooks") + "/Dee Linked/Imported Elsewhere.epub"
          File.delete(link)
          File.symlink("/references/ref-target/other.epub", link)
        end
        assert found.any? { |line| line.include?("Imported Elsewhere.epub:changed:") && line.include?("target") }, found.inspect
      end

      def test_an_unexpected_extra_database_and_a_dropped_index_are_reported
        found = mutate do |mutant|
          FileUtils.cp(File.join(mutant.storage, Layout::CACHE), File.join(mutant.storage, "production_extra.sqlite3"))
          sql(mutant, Layout::PRIMARY, "DROP INDEX index_users_on_username")
        end
        assert_includes found, "files:production_extra.sqlite3:file-added"
        assert_includes found, "production.sqlite3:users#index_users_on_username:index-lost"
      end

      def test_a_same_named_index_with_a_different_definition_is_reported
        found = mutate do |mutant|
          sql(mutant, Layout::PRIMARY, "DROP INDEX index_users_on_username")
          sql(mutant, Layout::PRIMARY, "CREATE INDEX index_users_on_username ON users (name)")
        end
        assert_equal [ "production.sqlite3:users#index_users_on_username:index-changed" ], found
      end

      def test_no_violation_names_a_secret_or_a_job_argument
        found = mutate do |mutant|
          sql(mutant, Layout::PRIMARY, "DELETE FROM download_clients")
          sql(mutant, Layout::QUEUE, "UPDATE solid_queue_jobs SET arguments = 'changed'")
        end
        text = found.join("\n")
        volume = self.class.fixture
        refute_includes text, "M2-JOB-ARGUMENT-SENTINEL"
        refute_includes text, volume.seed.dig("users", "reader", "password")
        refute_includes text, volume.secrets.fetch(:activity).fetch("token")
        assert_operator found.size, :<=, 60
      end
    end
  end
end
