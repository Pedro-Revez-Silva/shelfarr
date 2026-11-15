# frozen_string_literal: true

require_relative "support/volume_test_case"

module Migration
  module Volume
    class RollbackTest < VolumeTestCase
      WRITE_DURING_ROLLBACK = 'Setting.create!(key: "m2_written_during_rollback", value: "kept", value_type: "string", category: "general")'

      def upgraded_with_activity(previous_role)
        volume, pre = seeded(previous_role)
        container = harness.boot(volume, "candidate")
        harness.record_activity!(volume, container)
        harness.stop(container)
        [ volume, pre, harness.capture(volume) ]
      end

      def exercise_code_rollback(previous_role)
        volume, _pre, upgraded = upgraded_with_activity(previous_role)
        activity = volume.secrets.fetch(:activity)
        assert_equal 2, activity.dig("progress", "version")
        assert_equal "2026-11-15T03:05:00.456Z", activity.dig("progress", "observed_at")

        previous = harness.boot(volume, previous_role)
        assert_alive(previous, volume)
        docker.rails_runner(previous, WRITE_DURING_ROLLBACK)
        harness.stop(previous)
        rolled_back = harness.capture(volume)
        assert_clean Comparison.call(upgraded, rolled_back, allowances: Contracts.retained_activity.merge(new_row_tables: Contracts::QUEUE_GROWTH + [ "settings" ])), "activity lost by the code rollback"
        assert_includes rolled_back.databases.fetch(Layout::PRIMARY).tables.fetch("consumer_progresses").rows.keys, upgraded.databases.fetch(Layout::PRIMARY).tables.fetch("consumer_progresses").rows.keys.first

        forward = harness.boot(volume, "candidate")
        status, progress = harness.current_progress(forward, volume)
        assert_equal 200, status
        assert_equal activity.fetch("progress"), progress, "progress version, position or observed_at changed across the rollback"
        assert_equal 200, harness.api(forward, "GET", "/api/consumer/v1/me", activity.fetch("token")).status
        harness.stop(forward)
        rolled_forward = harness.capture(volume)
        assert_clean Comparison.call(rolled_back, rolled_forward, allowances: Contracts.same_schema), "state lost by rolling forward again"
        assert rolled_forward.databases.fetch(Layout::PRIMARY).tables.fetch("settings").rows.values.any? { |row| row.fetch("key").last == "m2_written_during_rollback" }
        [ volume, upgraded, rolled_back, rolled_forward ]
      end

      def test_previous_stable_release_runs_on_the_upgraded_volume_and_activity_survives_the_round_trip
        exercise_code_rollback("stable")
      end

      def test_previous_beta_image_runs_on_the_upgraded_volume_and_activity_survives_the_round_trip
        exercise_code_rollback("beta")
      end

      def test_old_stable_code_does_not_expose_the_new_activity_while_it_runs
        volume, = upgraded_with_activity("stable")
        previous = harness.boot(volume, "stable")
        assert_equal 404, harness.api(previous, "GET", "/api/consumer/v1/me", volume.secrets.fetch(:activity).fetch("token")).status
        harness.stop(previous)
      end

      def test_restoring_the_pre_upgrade_backup_is_not_activity_preserving
        volume, pre = seeded("stable")
        backup = File.join(volume.directory, "pre-upgrade")
        VolumeBackup.new(docker: docker).snapshot(storage: volume.storage, out: backup)
        container = harness.boot(volume, "candidate")
        harness.record_activity!(volume, container)
        harness.stop(container)
        upgraded = harness.capture(volume)
        assert upgraded.databases.fetch(Layout::PRIMARY).tables.fetch("consumer_progresses").rows.size == 1

        restored_directory = File.join(volume.directory, "restored")
        FileUtils.mkdir_p(restored_directory)
        VolumeBackup.new(docker: docker).restore(snapshot: backup, target: restored_directory)
        volume.storage = restored_directory
        restored = harness.capture(volume)
        assert_same_content(pre, restored)
        refute restored.databases.fetch(Layout::PRIMARY).tables.key?("consumer_progresses"), "the restored volume must predate the consumer tables"
        lost = harness.api(harness.boot(volume, "candidate"), "GET", "/api/consumer/v1/me", volume.secrets.fetch(:activity).fetch("token"))
        assert_equal 401, lost.status, "a token created after the snapshot cannot exist after restoring it"
        docker.cleanup
      end
    end
  end
end
