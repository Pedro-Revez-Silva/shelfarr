# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rubygems/package"
require_relative "../lib/volume_backup"

module Migration
  module Volume
    class SnapshotManifestTest < Minitest::Test
      def setup
        @directory = Dir.mktmpdir("snapshot-manifest-", ENV.fetch("TMPDIR"))
        archive = File.join(@directory, VolumeBackup::FILES_ARCHIVE)
        File.open(archive, "wb") { |file| Gem::Package::TarWriter.new(file) { |_tar| } }
        @manifest = { "format" => 1, "databases" => {}, "files" => {}, "key_files_present" => [], "archive_sha256" => Digest::SHA256.file(archive).hexdigest }
        @backup = VolumeBackup.new(docker: Object.new)
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
        FileUtils.mkdir_p(File.join(@directory, VolumeBackup::DATABASE_DIRECTORY))
        primary = File.join(@directory, VolumeBackup::DATABASE_DIRECTORY, Layout::PRIMARY)
        database = SQLite3::Database.new(primary)
        database.execute("CREATE TABLE records (id INTEGER PRIMARY KEY)")
        database.close
        @manifest["databases"] = { Layout::PRIMARY => { "sha256" => Digest::SHA256.file(primary).hexdigest } }
        write_manifest
        assert_equal @manifest, @backup.verify_snapshot(@directory)
      end
    end
  end
end
