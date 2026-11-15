# frozen_string_literal: true

require "digest"
require "find"
require "fileutils"
require "sqlite3"
require_relative "layout"
require_relative "scratch"
require_relative "command"
require_relative "docker"
require_relative "safe_copy"
require_relative "../../lib/database_snapshot"

module Migration
  module Volume
    class StateRefused < StandardError; end

    Entry = Data.define(:kind, :mode, :uid, :gid, :size, :mtime_ns, :ctime_ns, :inode, :digest, :target) do
      def fields = to_h
    end

    State = Data.define(:databases, :wal_bytes, :files, :media)

    class VolumeState
      def self.capture(storage:, media: {}, docker: nil, scratch: Scratch.root)
        new(storage: storage, media: media, docker: docker, scratch: scratch).capture
      end

      def initialize(storage:, media:, docker:, scratch:)
        @storage = storage
        @media = media
        @docker = docker
        @scratch = scratch
      end

      def capture
        raise StateRefused, "volume directory is missing or not a plain directory" unless File.directory?(@storage) && !File.symlink?(@storage)

        files = inventory(@storage)
        wal = Layout::DATABASES.to_h { |name| [ name, files.key?("#{name}-wal") ? files.fetch("#{name}-wal").size : nil ] }
        State.new(databases: databases(files), wal_bytes: wal, files: files, media: @media.transform_values { |path| inventory(path) })
      end

      private

      def databases(files)
        Layout::DATABASES.to_h do |name|
          next [ name, nil ] unless files.key?(name)

          [ name, snapshot(name) ]
        end
      end

      def snapshot(name)
        SafeCopy.open(@storage, name, scratch: @scratch) { |database| Migration::DatabaseSnapshot.build(database) }
      end

      def inventory(root)
        entries = {}
        unreadable = []
        Find.find(root) do |path|
          next if path == root

          relative = path.delete_prefix("#{root}/")
          stat = File.lstat(path)
          entries[relative] = describe(path, stat, unreadable, relative)
        end
        hash_as_root(root, unreadable, entries)
        entries
      end

      def describe(path, stat, unreadable, relative)
        kind = stat.symlink? ? "symlink" : (stat.directory? ? "directory" : (stat.file? ? "file" : "other"))
        digest = nil
        if stat.file?
          if File.readable?(path)
            digest = Digest::SHA256.file(path).hexdigest
          else
            unreadable << relative
          end
        end
        Entry.new(kind: kind, mode: stat.mode & 0o7777, uid: stat.uid, gid: stat.gid, size: stat.size, mtime_ns: (stat.mtime.to_r * 1_000_000_000).to_i,
                  ctime_ns: (stat.ctime.to_r * 1_000_000_000).to_i, inode: stat.ino, digest: digest, target: stat.symlink? ? File.readlink(path) : nil)
      end

      def hash_as_root(root, unreadable, entries)
        return if unreadable.empty?
        raise StateRefused, "files are unreadable and no container runtime was given to hash them" unless @docker

        arguments = unreadable.map { |name| "./#{name}" }
        output = Command.run!("docker", "run", "--rm", "--network", "none", "--user", "0:0", "--volume", "#{root}:/volume:ro", "--workdir", "/volume",
                              Docker::HELPER_IMAGE, "sha256sum", *arguments)
        output.each_line do |line|
          digest, name = line.chomp.split(/\s+/, 2)
          relative = name.delete_prefix("./")
          entries[relative] = entries.fetch(relative).with(digest: digest)
        end
      end
    end
  end
end
