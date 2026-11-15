# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require_relative "../../lib/contracts"
require_relative "../../lib/harness"
require_relative "../../lib/volume_backup"
require_relative "../../lib/queue_inventory"
require_relative "../../lib/scratch"

module Migration
  module Volume
    module Shared
      module_function

      def scratch
        @scratch ||= Dir.mktmpdir("shelfarr-m2-volume-", Scratch.root)
      end

      def docker
        @docker ||= Docker.new
      end

      def images
        @images ||= JSON.parse(ENV.fetch("SHELFARR_M2_IMAGES"))
      end

      def harness
        @harness ||= Harness.new(docker: docker, scratch: scratch, images: images)
      end

      def cleanup
        docker.cleanup
        FileUtils.rm_rf(scratch) unless ENV["SHELFARR_MIGRATION_KEEP"]
      end
    end

    Minitest.after_run { Shared.cleanup }

    class VolumeTestCase < Minitest::Test
      def harness = Shared.harness
      def docker = Shared.docker

      def assert_clean(violations, message = "volume contract violations")
        shown = violations.first(20).map(&:to_s)
        assert_empty violations, "#{message} (#{violations.size}): #{shown.join('; ')}"
      end

      CONTENT_FIELDS = %i[kind mode uid gid size mtime_ns digest target].freeze

      def assert_same_content(left, right)
        names = ->(state) { state.files.keys.reject { |name| Layout.database?(name) || Layout.sidecar?(name) }.sort }
        assert_equal names.call(left), names.call(right)
        names.call(left).each { |name| assert_equal left.files[name].to_h.slice(*CONTENT_FIELDS), right.files[name].to_h.slice(*CONTENT_FIELDS), name }
        Layout::DATABASES.each { |name| assert_equal left.databases.fetch(name).digest, right.databases.fetch(name).digest, name }
      end

      def assert_violation(violations, area, subject, reason)
        listed = violations.map(&:to_s)
        assert_includes listed, "#{area}:#{subject}:#{reason}", "expected #{area}:#{subject}:#{reason} among #{listed.first(10).inspect}"
      end

      def seeded(role = "stable", key_mode: :files, name: nil)
        volume = harness.volume_case(name || "#{role}-#{key_mode}-#{SecureRandom.hex(3)}", key_mode: key_mode)
        container = harness.boot(volume, role)
        harness.seed!(volume, container)
        cookie = harness.login(container, "m2_reader", volume.seed.dig("users", "reader", "password"))
        volume.secrets[:cookie] = cookie
        harness.stop(container)
        [ volume, harness.capture(volume) ]
      end

      def assert_alive(container, volume)
        outcome = harness.verify_state!(volume, container)
        assert_equal({ "otp_secret" => true, "backup_codes" => true, "api_key" => true, "password" => true, "password_authenticates" => true },
                     outcome.slice("otp_secret", "backup_codes", "api_key", "password", "password_authenticates"))
        assert_equal 200, harness.authenticated_status(container, "/requests", volume.secrets.fetch(:cookie)), "a session issued before the change must still be accepted"
        assert_equal 200, harness.bearer_status(container, "/api/v1/requests", volume.seed.dig("tokens", "legacy_admin", "raw")), "a token issued before the change must still be accepted"
        outcome
      end
    end
  end
end
