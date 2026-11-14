# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"

module Migration
  module FixtureIsolation
    class Refused < StandardError; end

    Paths = Data.define(:out, :primary_db, :queue_db, :cable_db, :media, :log, :tmp, :cache, :secrets, :expected) do
      def database_files = [ primary_db, queue_db, cable_db ]
    end

    FORBIDDEN_ENV_PATTERNS = [
      /\ADATABASE_URL\z/,
      /_DATABASE_URL\z/,
      /\ASECRET_KEY_BASE/,
      /\ARAILS_MASTER_KEY/,
      /\AACTIVE_RECORD_ENCRYPTION_/,
      /\ASHELFARR_/,
      /_FILE\z/,
      /\AKOBO_KEPUB_CACHE_PATH\z/,
      /\ARAILS_RELATIVE_URL_ROOT\z/
    ].freeze

    module_function

    def prepare!(out:, repo_root:, env: ENV)
      refuse_environment!(env)
      root = File.realpath(repo_root)
      target = resolve_out(out, root)
      paths = layout(target)
      create_directories(paths)
      apply_environment(paths, env)
      paths
    end

    def refuse_environment!(env)
      rails_env = env["RAILS_ENV"]
      raise Refused, "RAILS_ENV must be unset or test" unless rails_env.nil? || rails_env.empty? || rails_env == "test"

      offending = env.keys.select { |key| FORBIDDEN_ENV_PATTERNS.any? { |pattern| pattern.match?(key) } }
      raise Refused, "refusing to run with inherited configuration: #{offending.sort.join(', ')}" unless offending.empty?
    end

    def resolve_out(out, repo_root)
      raise Refused, "--out is required" if out.nil? || out.empty?
      raise Refused, "--out must be an absolute path" unless out.start_with?("/")
      raise Refused, "--out must not contain NUL" if out.include?("\0")

      absolute = File.expand_path(out)
      parent = File.dirname(absolute)
      raise Refused, "the parent of --out must already exist" unless File.directory?(parent)

      resolved = File.join(File.realpath(parent), File.basename(absolute))
      raise Refused, "--out must be a new private directory outside the repository" if inside?(resolved, repo_root)
      raise Refused, "--out already exists; choose a new directory" if File.exist?(resolved) || File.symlink?(resolved)

      resolved
    end

    def inside?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def layout(target)
      Paths.new(
        out: target,
        primary_db: File.join(target, "db", "primary.sqlite3"),
        queue_db: File.join(target, "scratch", "queue.sqlite3"),
        cable_db: File.join(target, "scratch", "cable.sqlite3"),
        media: File.join(target, "media"),
        log: File.join(target, "scratch", "log", "rails.log"),
        tmp: File.join(target, "scratch", "tmp"),
        cache: File.join(target, "scratch", "cache"),
        secrets: File.join(target, "secrets"),
        expected: File.join(target, "expected")
      )
    end

    def create_directories(paths)
      Dir.mkdir(paths.out, 0o700)
      [ File.dirname(paths.primary_db), paths.media, File.dirname(paths.log), paths.tmp, paths.cache, paths.secrets, paths.expected ].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
      end
    end

    def apply_environment(paths, env)
      env["RAILS_ENV"] = "test"
      env["DATABASE_URL"] = sqlite_url(paths.primary_db)
      env["QUEUE_DATABASE_URL"] = sqlite_url(paths.queue_db)
      env["CABLE_DATABASE_URL"] = sqlite_url(paths.cable_db)
      env["TMPDIR"] = paths.tmp
      env["BOOTSNAP_CACHE_DIR"] = File.join(paths.cache, "bootsnap")
      env["XDG_CACHE_HOME"] = paths.cache
      env["BUNDLE_FROZEN"] = "true"
      env["SECRET_KEY_BASE"] = SecureRandom.hex(64)
      env.delete("CI")
    end

    def sqlite_url(path)
      "sqlite3://#{path}"
    end

    def redirect_credentials(config, paths)
      config.credentials.content_path = Pathname.new(File.join(paths.tmp, "credentials.yml.enc"))
      config.credentials.key_path = Pathname.new(File.join(paths.tmp, "master.key"))
    end

    def verify_credentials!(config, paths)
      [ config.credentials.content_path, config.credentials.key_path ].each do |path|
        raise Refused, "Rails credential paths are not isolated" unless inside?(File.expand_path(path.to_s), paths.out)
      end
    end

    def verify_databases!(configurations, paths)
      allowed = paths.database_files.to_h { |file| [ file, true ] }
      configs = configurations.configs_for(env_name: "test")
      raise Refused, "no test database configurations resolved" if configs.empty?

      configs.each do |config|
        database = config.database.to_s
        raise Refused, "database #{config.name} is not an isolated fixture path" unless allowed.key?(database)
      end
    end
  end
end
