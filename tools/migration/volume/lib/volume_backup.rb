# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "sqlite3"
require "time"
require_relative "layout"
require_relative "docker"
require_relative "volume_guard"
require_relative "volume_state"
require_relative "scratch"

module Migration
  module Volume
    class BackupRefused < StandardError; end

    class VolumeBackup
      FORMAT = 1
      MANIFEST = "snapshot.json"
      FILES_ARCHIVE = "files.tar"
      DATABASE_DIRECTORY = "databases"
      MAX_MANIFEST_BYTES = 16 * 1024 * 1024
      DIGEST = /\A[0-9a-f]{64}\z/

      def initialize(docker:, guard: nil, scratch: Scratch.root)
        @docker = docker
        @guard = guard || VolumeGuard.new(docker: docker)
        @scratch = scratch
      end

      def snapshot(storage:, out:, environment_keys: false)
        @guard.assert_quiescent!(storage)
        @guard.assert_keys_present!(storage, environment_keys: environment_keys)
        raise BackupRefused, "refusing: #{out} already exists" if File.exist?(out)
        raise BackupRefused, "refusing: backup directory must be outside the volume" if out == storage || out.start_with?("#{storage}/")

        FileUtils.mkdir_p(File.join(out, DATABASE_DIRECTORY), mode: 0o700)
        begin
          databases = copy_databases(storage, out)
          archive_files(storage, out)
          @guard.assert_quiescent!(storage)
          write_manifest(storage, out, databases)
        rescue StandardError
          FileUtils.rm_rf(out)
          raise
        end
        JSON.parse(File.read(File.join(out, MANIFEST)))
      end

      def restore(snapshot:, target:)
        manifest = verify_snapshot(snapshot)
        @guard.assert_empty_target!(target)
        extract_archive(snapshot, target)
        manifest.fetch("databases").each { |name, entry| place_database(snapshot, target, name, entry) }
        verify_restored(manifest, target)
        manifest
      end

      def verify_snapshot(snapshot)
        path = File.join(snapshot, MANIFEST)
        raise BackupRefused, "refusing: #{snapshot} has no #{MANIFEST}; the snapshot is incomplete" unless File.file?(path)

        content = File.binread(path, MAX_MANIFEST_BYTES + 1) || ""
        assert_manifest_size!(content.bytesize)
        manifest = JSON.parse(content)
        raise BackupRefused, "refusing: unsupported snapshot format" unless manifest.is_a?(Hash) && manifest["format"] == FORMAT

        databases = manifest["databases"]
        raise BackupRefused, "refusing: snapshot must include the primary database" unless databases.is_a?(Hash) && databases.key?(Layout::PRIMARY)

        unknown = databases.keys - Layout::DATABASES
        raise BackupRefused, "refusing: the manifest names a database outside the volume contract" unless unknown.empty?

        validate_restore_metadata!(manifest)
        manifest.fetch("databases").each do |name, entry|
          file = File.join(snapshot, DATABASE_DIRECTORY, name)
          raise BackupRefused, "refusing: snapshot database #{name} is missing" unless File.file?(file)
          raise BackupRefused, "refusing: snapshot database #{name} fails its recorded digest" unless Digest::SHA256.file(file).hexdigest == entry.fetch("sha256")
        end
        archive = File.join(snapshot, FILES_ARCHIVE)
        raise BackupRefused, "refusing: snapshot archive fails its recorded digest" unless File.file?(archive) && Digest::SHA256.file(archive).hexdigest == manifest.fetch("archive_sha256")

        manifest
      rescue JSON::ParserError
        raise BackupRefused, "refusing: snapshot manifest is not valid JSON"
      end

      private

      def validate_restore_metadata!(manifest)
        databases = manifest.fetch("databases")
        valid = databases.values.all? do |entry|
          entry.is_a?(Hash) && valid_digest?(entry["sha256"]) && valid_integer?(entry["uid"], 4_294_967_294) &&
            valid_integer?(entry["gid"], 4_294_967_294) && valid_integer?(entry["mode"], 0o7777)
        end
        files = manifest["files"]
        valid &&= files.is_a?(Hash) && files.all? { |name, entry| valid_relative_path?(name) && valid_file_metadata?(entry) }
        valid &&= valid_digest?(manifest["archive_sha256"])
        raise BackupRefused, "refusing: snapshot restore metadata is invalid" unless valid
      end

      def valid_integer?(value, maximum)
        value.is_a?(Integer) && value.between?(0, maximum)
      end

      def valid_digest?(value)
        value.is_a?(String) && value.match?(DIGEST)
      end

      def valid_relative_path?(name)
        name.is_a?(String) && !name.empty? && !name.start_with?("/") && !name.include?("\0") && name.split("/", -1).none? { |part| [ "", ".", ".." ].include?(part) }
      end

      def valid_file_metadata?(entry)
        return false unless entry.is_a?(Hash) && valid_integer?(entry["mode"], 0o7777)
        return valid_digest?(entry["digest"]) if entry["kind"] == "file"

        %w[directory symlink other].include?(entry["kind"]) && entry.key?("digest") && entry["digest"].nil?
      end

      def assert_manifest_size!(size)
        raise BackupRefused, "refusing: snapshot manifest exceeds 16 MiB" if size > MAX_MANIFEST_BYTES
      end

      def copy_databases(storage, out)
        raise BackupRefused, "refusing: #{Layout::PRIMARY} is required" unless File.file?(File.join(storage, Layout::PRIMARY))

        Layout::DATABASES.each_with_object({}) do |name, memo|
          source = File.join(storage, name)
          next unless File.file?(source)

          destination = File.join(out, DATABASE_DIRECTORY, name)
          SafeCopy.open(storage, name, scratch: @scratch) do |database|
            integrity = database.execute("PRAGMA integrity_check").flatten
            raise BackupRefused, "refusing: #{name} fails its integrity check" unless integrity == [ "ok" ]

            clone = SQLite3::Database.new(destination)
            backup = SQLite3::Backup.new(clone, "main", database, "main")
            backup.step(-1)
            backup.finish
            clone.close
          end
          stat = File.stat(source)
          memo[name] = { "sha256" => Digest::SHA256.file(destination).hexdigest, "size" => File.size(destination), "uid" => stat.uid, "gid" => stat.gid,
                         "mode" => stat.mode & 0o7777, "wal_bytes_at_source" => File.exist?("#{source}-wal") ? File.size("#{source}-wal") : 0 }
        end
      end

      def archive_files(storage, out)
        excludes = Layout::DATABASES.flat_map { |name| [ name ] + Layout::SIDECAR_SUFFIXES.map { |suffix| "#{name}#{suffix}" } }.map { |name| "--exclude=./#{name}" }.join(" ")
        script = "tar -cf /out/#{FILES_ARCHIVE} --format=posix --pax-option=delete=atime,delete=ctime --numeric-owner #{excludes} -C /volume . && chown #{Process.uid}:#{Process.gid} /out/#{FILES_ARCHIVE} && chmod 0600 /out/#{FILES_ARCHIVE}"
        result = @docker.helper(volumes: [ [ storage, "/volume", "ro" ], [ out, "/out", "rw" ] ], script: script)
        raise BackupRefused, "refusing: archiving the volume files failed" unless result.success?
      end

      def write_manifest(storage, out, databases)
        state = VolumeState.capture(storage: storage, docker: @docker, scratch: @scratch)
        files = state.files.reject { |name, _| Layout.database?(name) || Layout.sidecar?(name) }.transform_values { |entry| entry.to_h.slice(:kind, :mode, :uid, :gid, :size, :mtime_ns, :digest, :target) }
        manifest = { "format" => FORMAT, "created_at" => Time.now.utc.iso8601, "databases" => databases, "files" => files,
                     "archive_sha256" => Digest::SHA256.file(File.join(out, FILES_ARCHIVE)).hexdigest,
                     "key_files_present" => Layout::KEY_FILES.select { |name| files.key?(name) } }
        temporary = File.join(out, "#{MANIFEST}.partial")
        content = JSON.pretty_generate(manifest)
        assert_manifest_size!(content.bytesize)
        validate_restore_metadata!(JSON.parse(content))
        File.write(temporary, content, perm: 0o600)
        File.rename(temporary, File.join(out, MANIFEST))
      end

      def extract_archive(snapshot, target)
        script = "tar -xf /snapshot/#{FILES_ARCHIVE} --numeric-owner -C /target"
        result = @docker.helper(volumes: [ [ snapshot, "/snapshot", "ro" ], [ target, "/target", "rw" ] ], script: script)
        raise BackupRefused, "refusing: extracting the volume files failed" unless result.success?
      end

      def place_database(snapshot, target, name, entry)
        script = %(install -o "$1" -g "$2" -m "$3" "/snapshot/#{DATABASE_DIRECTORY}/$4" "/target/$4")
        arguments = [ Integer(entry.fetch("uid")), Integer(entry.fetch("gid")), format("%o", Integer(entry.fetch("mode"))), name ]
        result = @docker.helper(volumes: [ [ snapshot, "/snapshot", "ro" ], [ target, "/target", "rw" ] ], script: script, arguments: arguments)
        raise BackupRefused, "refusing: placing #{name} failed" unless result.success?
      end

      def verify_restored(manifest, target)
        state = VolumeState.capture(storage: target, docker: @docker, scratch: @scratch)
        manifest.fetch("databases").each_key do |name|
          raise BackupRefused, "restored #{name} fails its integrity check" unless state.databases.fetch(name)&.integrity == [ "ok" ]
        end
        manifest.fetch("files").each do |name, entry|
          restored = state.files[name]
          raise BackupRefused, "restored volume lacks #{name}" unless restored
          raise BackupRefused, "restored #{name} differs from the snapshot" unless restored.digest == entry["digest"] && restored.kind == entry["kind"] && restored.mode == entry["mode"]
        end
      end
    end
  end
end
