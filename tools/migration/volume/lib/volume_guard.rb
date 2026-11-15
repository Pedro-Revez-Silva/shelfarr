# frozen_string_literal: true

require_relative "safe_copy"
require_relative "layout"
require_relative "docker"

module Migration
  module Volume
    class Refusal < StandardError; end

    class VolumeGuard
      ENVELOPE = '{"p":"'
      TEXT_AFFINITY = /CHAR|CLOB|TEXT/i

      def initialize(docker:, proc_root: "/proc")
        @docker = docker
        @proc_root = proc_root
      end

      def assert_quiescent!(storage)
        assert_plain_directory!(storage)
        active = containers(storage)
        raise Refusal, "refusing: #{active.size} container(s) with the volume mounted are active (#{active.join(', ')})" unless active.empty?

        holders = open_holders(storage)
        raise Refusal, "refusing: #{holders.size} process(es) hold files of the volume open" unless holders.empty?

        hot = Dir.children(storage).select { |name| name.end_with?("-journal") }
        raise Refusal, "refusing: a hot rollback journal exists (#{hot.join(', ')}); start the application once so SQLite can recover it" unless hot.empty?

        true
      end

      def assert_plain_directory!(storage)
        raise Refusal, "refusing: #{storage.inspect} is not an absolute path" unless storage.start_with?("/")
        raise Refusal, "refusing: the volume directory does not exist" unless File.directory?(storage)
        raise Refusal, "refusing: the volume path crosses a symbolic link" unless File.realpath(storage) == File.expand_path(storage)
        raise Refusal, "refusing: the volume has no #{Layout::PRIMARY}" unless File.file?(File.join(storage, Layout::PRIMARY))

        linked = Dir.children(storage).select { |name| File.symlink?(File.join(storage, name)) && (Layout.database?(name) || Layout.sidecar?(name) || Layout::KEY_FILES.include?(name)) }
        raise Refusal, "refusing: #{linked.join(', ')} is a symbolic link; a link could point at a database another process holds open" unless linked.empty?
      end

      def assert_empty_target!(target)
        raise Refusal, "refusing: restore target is not an absolute path" unless target.start_with?("/")
        raise Refusal, "refusing: restore target does not exist" unless File.directory?(target)
        raise Refusal, "refusing: restore target crosses a symbolic link" unless File.realpath(target) == File.expand_path(target)
        raise Refusal, "refusing: restore target is not empty; restore only into a new empty directory" unless Dir.children(target).empty?

        active = containers(target)
        raise Refusal, "refusing: a container that mounts the restore target is active" unless active.empty?
      end

      def key_material_missing?(storage, environment_keys: false)
        return false if environment_keys

        files = Layout::KEY_FILES.select { |name| File.exist?(File.join(storage, name)) }
        files.size < Layout::KEY_FILES.size && encrypted_values?(storage)
      end

      def assert_keys_present!(storage, environment_keys: false)
        return true unless key_material_missing?(storage, environment_keys: environment_keys)

        raise Refusal, "refusing: the volume holds encrypted values but key material is missing; the production entrypoint would generate new keys and make them unreadable"
      end

      def encrypted_values?(storage)
        SafeCopy.open(storage, Layout::PRIMARY) do |database|
          database.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").flatten.any? do |table|
            database.execute("PRAGMA table_info(\"#{table}\")").any? do |_cid, column, type|
              next false unless type.to_s.match?(TEXT_AFFINITY)

              database.get_first_value("SELECT 1 FROM \"#{table}\" WHERE substr(\"#{column}\", 1, #{ENVELOPE.length}) = ? LIMIT 1", ENVELOPE)
            end
          end
        end
      end

      private

      def containers(path)
        @docker.containers_mounting(path, active_only: true)
      rescue CommandFailed
        raise Refusal, "refusing: the container runtime could not prove the volume is not in use"
      end

      def open_holders(storage)
        prefix = "#{File.realpath(storage)}/"
        Dir.glob(File.join(@proc_root, "[0-9]*", "fd", "*")).select do |descriptor|
          File.readlink(descriptor).to_s.start_with?(prefix)
        rescue SystemCallError
          false
        end
      end
    end
  end
end
