# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "securerandom"
require "uri"
require_relative "docker"
require_relative "safe_copy"
require_relative "media_fixture"
require_relative "volume_state"
require_relative "comparison"

module Migration
  module Volume
    class HarnessError < StandardError; end

    class VolumeCase
      attr_reader :name, :directory, :media, :key_mode, :environment, :secrets
      attr_accessor :seed, :storage

      def initialize(name:, directory:, key_mode:)
        @name = name
        @directory = directory
        @storage = File.join(directory, "storage")
        @key_mode = key_mode
        @environment = key_mode == :environment ? generated_keys : {}
        @secrets = {}
        FileUtils.mkdir_p(@storage)
        File.chmod(0o700, @storage)
        @media = MediaFixture.new(File.join(directory, "media")).build
      end

      def generated_keys
        {
          "SECRET_KEY_BASE" => SecureRandom.hex(64),
          "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => Base64.strict_encode64(SecureRandom.random_bytes(32)),
          "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => Base64.strict_encode64(SecureRandom.random_bytes(32)),
          "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => Base64.strict_encode64(SecureRandom.random_bytes(32))
        }
      end
    end

    class Harness
      attr_reader :docker, :scratch

      def initialize(docker:, scratch:, images:)
        @docker = docker
        @scratch = scratch
        @images = images
        @counter = 0
      end

      def image(role) = @images.fetch(role)

      def volume_case(name, key_mode: :files)
        VolumeCase.new(name: name, directory: File.join(@scratch, "case-#{name}"), key_mode: key_mode)
      end

      def boot(volume, role, environment: {}, wait: true, cpus: nil)
        @counter += 1
        container = @docker.start(image: image(role), role: "#{volume.name}-#{role}-#{@counter}", storage: volume.storage,
                                  media: volume.media.mounts, environment: volume.environment.merge(environment), cpus: cpus)
        @docker.wait_ready(container) if wait
        container
      end

      def kill_when_applied(volume, container, count:, timeout: 120)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        database = nil
        loop do
          return :exited unless @docker.running?(container)
          return :timeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          database ||= open_reader(volume)
          applied = database&.get_first_value("SELECT COUNT(*) FROM schema_migrations")
          next unless applied && applied >= count

          @docker.kill(container)
          @docker.remove(container)
          return :killed
        rescue SQLite3::Exception
          database&.close
          database = nil
        end
      ensure
        database&.close
      end

      def open_reader(volume)
        path = File.join(volume.storage, Layout::PRIMARY)
        return nil unless File.exist?("#{path}-shm")

        SQLite3::Database.new(path, readonly: true).tap { |database| database.busy_timeout = 50 }
      end

      def inspect_primary(volume)
        SafeCopy.open(volume.storage, Layout::PRIMARY, scratch: @scratch) do |database|
          {
            "integrity" => database.execute("PRAGMA integrity_check").flatten,
            "versions" => database.execute("SELECT version FROM schema_migrations ORDER BY version").flatten,
            "books" => database.execute("SELECT COUNT(*), SUM(id), SUM(LENGTH(title)) FROM books").first,
            "index" => database.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'index_books_on_consumer_title'") == 1
          }
        end
      end

      def add_bulk_books(volume, rows)
        database = SQLite3::Database.new(File.join(volume.storage, Layout::PRIMARY))
        database.execute(<<~SQL)
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < #{Integer(rows)})
          INSERT INTO books (title, book_type, content_kind, file_path, language, metadata_source, created_at, updated_at)
          SELECT 'Bulk ' || i, 0, 0, '/audiobooks/bulk/' || i, 'en', 'openlibrary', '2026-01-01 00:00:00.000000', '2026-01-01 00:00:00.000000' FROM n
        SQL
        database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      ensure
        database&.close
      end

      def stop(container)
        @docker.stop(container)
        @docker.remove(container)
      end

      def crash(container)
        @docker.kill(container)
        @docker.remove(container)
      end

      def capture(volume)
        VolumeState.capture(storage: volume.storage, media: volume.media.tree_roots, docker: @docker, scratch: @scratch)
      end

      def seed!(volume, container)
        plan = { "settings" => { "audiobook_output_path" => "/audiobooks", "ebook_output_path" => "/ebooks" }, "books" => volume.media.books }
        source = File.read(File.join(__dir__, "..", "rails", "seed_volume.rb"))
        output = @docker.rails_runner(container, source, environment: { "M2_SEED" => JSON.generate(plan) })
        line = output.lines.reverse.find { |candidate| candidate.start_with?("M2-RESULT ") }
        raise HarnessError, "seed produced no result" unless line

        volume.seed = JSON.parse(line.delete_prefix("M2-RESULT "))
      end

      def login(container, username, password)
        form = @docker.request(container, "GET", "/session/new")
        token = form.body[/name="csrf-token" content="([^"]+)"/, 1] || form.body[/name="authenticity_token" value="([^"]+)"/, 1]
        raise HarnessError, "no CSRF token on the sign-in page" unless token

        cookie_name = form.headers["set-cookie"].first.to_s[/\A([^=]+)=/, 1]
        jar = "#{cookie_name}=#{form.cookie(cookie_name)}"
        body = URI.encode_www_form("authenticity_token" => token, "username" => username, "password" => password)
        response = @docker.request(container, "POST", "/session", headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: body, cookie: jar)
        signed = response.cookie("session_id")
        raise HarnessError, "sign-in did not issue a session (status #{response.status})" unless signed

        "session_id=#{signed}"
      end

      def verify_state!(volume, container)
        seed = volume.seed
        expectation = seed.fetch("plaintext_digests").merge("otp_user_id" => seed.dig("users", "otp", "id"), "reader_id" => seed.dig("users", "reader", "id"),
                                                             "reader_password" => seed.dig("users", "reader", "password"))
        source = File.read(File.join(__dir__, "..", "rails", "verify_volume.rb"))
        output = @docker.rails_runner(container, source, environment: { "M2_EXPECT" => JSON.generate(expectation) })
        JSON.parse(output.lines.reverse.find { |line| line.start_with?("M2-RESULT ") }.delete_prefix("M2-RESULT "))
      end

      def record_activity!(volume, container)
        reader = volume.seed.dig("users", "reader", "id")
        source = File.read(File.join(__dir__, "..", "rails", "post_upgrade_activity.rb"))
        output = @docker.rails_runner(container, source, environment: { "M2_ACTIVITY" => JSON.generate("reader_id" => reader) })
        activity = JSON.parse(output.lines.reverse.find { |line| line.start_with?("M2-RESULT ") }.delete_prefix("M2-RESULT "))
        raw = activity.fetch("raw")
        library = JSON.parse(api(container, "GET", "/api/consumer/v1/library", raw).body)
        audio = library.fetch("items").find { |item| item["book_type"] == "audiobook" && item["assets"].to_a.any? }
        raise HarnessError, "no audiobook publication with an asset" unless audio

        asset_id = audio.fetch("assets").first.fetch("id")
        book_id = audio.fetch("id")
        first = progress!(container, raw, book_id, asset_id, expected_version: 0, seconds: 120.5, observed_at: "2026-11-15T03:00:00.123Z")
        second = progress!(container, raw, book_id, asset_id, expected_version: 1, seconds: 360.25, observed_at: "2026-11-15T03:05:00.456Z")
        grant = api(container, "POST", "/api/consumer/v1/auth/device", nil, body: JSON.generate("client_name" => "m2 device"), json: true)
        volume.secrets[:activity] = { "token" => raw, "book_id" => book_id, "asset_id" => asset_id, "progress" => second.fetch("progress"), "first" => first.fetch("progress"), "grant_status" => grant.status, "jobs" => activity.fetch("jobs"), "unknown_job" => activity.fetch("unknown") }
      end

      def progress!(container, raw, book_id, asset_id, expected_version:, seconds:, observed_at:)
        body = JSON.generate("asset_id" => asset_id, "expected_version" => expected_version, "client_mutation_id" => SecureRandom.uuid, "position_seconds" => seconds, "observed_at" => observed_at)
        response = api(container, "PUT", "/api/consumer/v1/library/#{book_id}/progress", raw, body: body, json: true)
        raise HarnessError, "progress write refused with status #{response.status}" unless response.status == 200

        JSON.parse(response.body)
      end

      def current_progress(container, volume)
        activity = volume.secrets.fetch(:activity)
        response = api(container, "GET", "/api/consumer/v1/library/#{activity.fetch('book_id')}/progress", activity.fetch("token"))
        [ response.status, response.status == 200 ? JSON.parse(response.body).fetch("progress") : nil ]
      end

      def api(container, verb, path, raw, body: nil, json: false)
        headers = { "Accept" => "application/json" }
        headers["Authorization"] = "Bearer #{raw}" if raw
        headers["Content-Type"] = "application/json" if json
        @docker.request(container, verb, path, headers: headers, body: body)
      end

      def authenticated_status(container, path, cookie)
        @docker.request(container, "GET", path, cookie: cookie).status
      end

      def bearer_status(container, path, raw_token)
        @docker.request(container, "GET", path, headers: { "Authorization" => "Bearer #{raw_token}", "Accept" => "application/json" }).status
      end
    end
  end
end
