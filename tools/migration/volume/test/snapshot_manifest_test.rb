# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rubygems/package"
require "open3"
require_relative "../lib/volume_backup"

module Migration
  module Volume
    class SnapshotManifestTest < Minitest::Test
      def setup
        @directory = Dir.mktmpdir("snapshot-manifest-", Scratch.root)
        archive = File.join(@directory, VolumeBackup::FILES_ARCHIVE)
        File.open(archive, "wb") { |file| Gem::Package::TarWriter.new(file) { |_tar| } }
        @manifest = { "format" => 1, "databases" => {}, "files" => {}, "key_files_present" => [], "archive_sha256" => Digest::SHA256.file(archive).hexdigest }
        @backup = VolumeBackup.new(docker: Object.new, guard: Object.new)
      end

      def teardown
        FileUtils.remove_entry(@directory)
      end

      def write_manifest
        File.write(File.join(@directory, VolumeBackup::MANIFEST), JSON.generate(@manifest))
      end

      def test_a_snapshot_without_the_primary_database_is_refused
        @manifest["databases"] = { Layout::QUEUE => {} }
        write_manifest
        error = assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
        assert_match(/primary database/, error.message)
      end

      def test_an_empty_database_inventory_is_never_a_restorable_snapshot
        write_manifest
        assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
      end

      def test_missing_or_invalid_database_inventories_are_refused
        [ nil, [], {}, "invalid" ].each do |inventory|
          @manifest["databases"] = inventory
          write_manifest
          assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
        end
        @manifest.delete("databases")
        write_manifest
        assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
      end

      def test_a_valid_primary_database_does_not_require_unused_secondary_databases
        prepare_primary
        write_manifest
        assert_equal @manifest, @backup.verify_snapshot(@directory)
      end

      def prepare_primary
        FileUtils.mkdir_p(File.join(@directory, VolumeBackup::DATABASE_DIRECTORY))
        primary = File.join(@directory, VolumeBackup::DATABASE_DIRECTORY, Layout::PRIMARY)
        database = SQLite3::Database.new(primary)
        database.execute("CREATE TABLE records (id INTEGER PRIMARY KEY)")
        database.close
        @manifest["databases"] = { Layout::PRIMARY => { "sha256" => Digest::SHA256.file(primary).hexdigest,
          "uid" => Process.uid, "gid" => Process.gid, "mode" => 0o600, "size" => File.size(primary), "wal_bytes_at_source" => 0 } }
      end

      def test_invalid_database_metadata_is_refused_before_the_target_is_checked
        prepare_primary
        valid = JSON.generate(@manifest)
        %w[sha256 uid gid mode].each do |field|
          @manifest = JSON.parse(valid)
          @manifest.fetch("databases").fetch(Layout::PRIMARY).delete(field)
          write_manifest
          assert_raises(BackupRefused) { @backup.restore(snapshot: @directory, target: "unreached") }
        end
        { "uid" => [ -1, "0", nil, 4_294_967_295 ], "gid" => [ -1, 1.5 ], "mode" => [ -1, "0600", 0o10000 ], "sha256" => [ nil, 123, "not-a-digest" ] }.each do |field, values|
          values.each do |value|
            @manifest = JSON.parse(valid)
            @manifest.fetch("databases")[Layout::PRIMARY][field] = value
            write_manifest
            assert_raises(BackupRefused) { @backup.restore(snapshot: @directory, target: "unreached") }
          end
        end
      end

      def test_invalid_file_metadata_is_refused_before_the_target_is_checked
        prepare_primary
        valid = JSON.generate(@manifest)
        [ nil, [], "invalid", { "artifact" => nil }, { "artifact" => {} }, { "artifact" => { "kind" => "file", "mode" => 0o600, "digest" => nil } },
          { "artifact" => { "kind" => "file", "mode" => 0o600, "digest" => "invalid" } }, { "artifact" => { "kind" => "directory", "mode" => 0o755 } },
          { "artifact" => { "kind" => "unknown", "mode" => 0o600, "digest" => nil } }, { "artifact" => { "kind" => "directory", "mode" => "0755", "digest" => nil } } ].each do |files|
          @manifest = JSON.parse(valid)
          @manifest["files"] = files
          write_manifest
          assert_raises(BackupRefused) { @backup.restore(snapshot: @directory, target: "unreached") }
        end
        @manifest = JSON.parse(valid)
        @manifest.delete("files")
        write_manifest
        assert_raises(BackupRefused) { @backup.restore(snapshot: @directory, target: "unreached") }
        [ "", "../escape", "/absolute", "nested//entry" ].each do |name|
          @manifest = JSON.parse(valid)
          @manifest["files"] = { name => { "kind" => "directory", "mode" => 0o755, "digest" => nil } }
          write_manifest
          assert_raises(BackupRefused) { @backup.restore(snapshot: @directory, target: "unreached") }
        end
      end

      def test_invalid_json_and_archive_metadata_are_refused
        prepare_primary
        [ "", "{broken", "[]", "null", "42" ].each do |text|
          File.write(File.join(@directory, VolumeBackup::MANIFEST), text)
          assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
        end
        [ nil, 1, "bad" ].each do |value|
          @manifest["archive_sha256"] = value
          write_manifest
          assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
        end
      end

      def test_the_cli_refuses_incomplete_metadata_without_writing_the_target
        prepare_primary
        archive = File.join(@directory, VolumeBackup::FILES_ARCHIVE)
        File.open(archive, "wb") do |file|
          Gem::Package::TarWriter.new(file) { |tar| tar.add_file_simple("artifact", 0o600, 7) { |entry| entry.write("content") } }
        end
        @manifest["archive_sha256"] = Digest::SHA256.file(archive).hexdigest
        @manifest.fetch("databases").fetch(Layout::PRIMARY).delete("uid")
        write_manifest
        target = File.join(@directory, "target")
        Dir.mkdir(target)
        command = File.expand_path("../volume", __dir__)
        output, error, status = Open3.capture3(RbConfig.ruby, command, "restore", "--snapshot", @directory, "--target", target)
        assert_empty Dir.children(target)
        assert_equal 3, status.exitstatus, error
        assert_empty output
        assert_equal 1, error.lines.size
        assert_equal "refusing: snapshot restore metadata is invalid\n", error
      end

      def test_oversized_manifests_are_refused_before_json_parsing
        prepare_primary
        @manifest["padding"] = "x" * (16 * 1024 * 1024)
        write_manifest
        error = assert_raises(BackupRefused) { @backup.verify_snapshot(@directory) }
        assert_match(/exceeds 16 MiB/, error.message)
      end
    end
  end
end
