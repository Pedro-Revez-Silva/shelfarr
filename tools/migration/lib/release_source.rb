# frozen_string_literal: true

require "digest"
require "open3"

module Migration
  class ReleaseSource
    class Unavailable < StandardError; end

    TAG = "v2026.11.05.1"
    COMMIT = "96333c6674a21701f7229c1a51038dc3b117c1a0"
    TREE = "c9a17fcfa4591898ac47a299e8fab09ecd2c15c1"
    SCHEMA_BLOB = "ac0c524fecaf0552a2721d1817c792448fd338f8"
    MIGRATIONS_TREE = "65596153c4eb018fcc57fa563302af6ce94c52f4"
    SCHEMA_VERSION = "20261102120000"
    MIGRATION_FILE = /\A(\d{14})_([a-z0-9_]+)\.rb\z/

    Entry = Data.define(:version, :file, :blob)

    def initialize(repo_root)
      @repo_root = repo_root
    end

    def resolve!
      verify_object("#{COMMIT}^{commit}", COMMIT, "commit")
      verify_object("#{COMMIT}^{tree}", TREE, "tree")
      verify_object("#{COMMIT}:db/schema.rb", SCHEMA_BLOB, "schema")
      verify_object("#{COMMIT}:db/migrate", MIGRATIONS_TREE, "migrations")
      self
    end

    def schema_ruby
      git("cat-file", "blob", SCHEMA_BLOB)
    end

    def migrations
      @migrations ||= git("ls-tree", "-z", MIGRATIONS_TREE).split("\0").map do |entry|
        metadata, file = entry.split("\t", 2)
        match = MIGRATION_FILE.match(file)
        raise Unavailable, "release migration tree holds an unexpected entry" unless match && metadata.split(" ")[1] == "blob"

        Entry.new(version: match[1], file: file, blob: metadata.split(" ")[2])
      end.sort_by(&:version)
    end

    def versions
      migrations.map(&:version)
    end

    def tag_state
      output, status = capture("rev-parse", "--verify", "--quiet", "refs/tags/#{TAG}^{commit}")
      return "absent" unless status.success?

      output.strip == COMMIT ? "matches-pinned-commit" : "points-elsewhere"
    end

    def new_migrations(migrate_directory)
      present = Dir.children(migrate_directory).grep(MIGRATION_FILE).to_h { |file| [ file, blob_id(File.join(migrate_directory, file)) ] }
      migrations.each do |release|
        raise Unavailable, "shipped migration #{release.version} changed since the release" unless present[release.file] == release.blob
      end
      added = present.keys - migrations.map(&:file)
      versions = added.map { |file| MIGRATION_FILE.match(file)[1] }.sort
      raise Unavailable, "a new migration is not newer than the release schema" unless versions.all? { |version| version > SCHEMA_VERSION }

      versions
    end

    def provenance
      {
        "tag" => TAG, "tag_state" => tag_state, "commit" => COMMIT, "tree" => TREE, "schema_blob" => SCHEMA_BLOB,
        "migrations_tree" => MIGRATIONS_TREE, "schema_version" => SCHEMA_VERSION, "migration_count" => migrations.size,
        "schema_sha256" => Digest::SHA256.hexdigest(schema_ruby)
      }
    end

    def blob_id(path)
      content = File.binread(path)
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
    end

    private

    def verify_object(expression, expected, label)
      output, status = capture("rev-parse", "--verify", "--quiet", expression)
      raise Unavailable, "release #{label} object is not present locally; this tool never fetches" unless status.success?
      raise Unavailable, "release #{label} object differs from the pinned identity" unless output.strip == expected
    end

    def git(*arguments)
      output, status = capture(*arguments)
      raise Unavailable, "could not read the release object" unless status.success?

      output
    end

    def capture(*arguments)
      environment = { "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0",
                      "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }
      output, _error, status = Open3.capture3(environment, "git", "-C", @repo_root, *arguments, unsetenv_others: true, binmode: true)
      [ output.force_encoding(Encoding::UTF_8), status ]
    end
  end
end
