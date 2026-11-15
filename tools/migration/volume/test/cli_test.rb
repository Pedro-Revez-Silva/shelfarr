# frozen_string_literal: true

require_relative "support/volume_test_case"

module Migration
  module Volume
    class CliTest < VolumeTestCase
      EXECUTABLE = File.expand_path("../volume", __dir__)

      def cli(*arguments)
        Command.capture(RbConfig.ruby, EXECUTABLE, *arguments, environment: { "TMPDIR" => harness.scratch })
      end

      def test_check_refuses_a_running_volume_and_accepts_a_stopped_one
        volume, = seeded("beta")
        container = harness.boot(volume, "beta")
        running = cli("check", "--storage", volume.storage)
        assert_equal 3, running.status.exitstatus
        assert_match(/active/, running.error)
        harness.stop(container)
        stopped = cli("check", "--storage", volume.storage)
        assert_equal 0, stopped.status.exitstatus, stopped.error
        assert_equal({ "quiescent" => true, "key_material" => "present-or-environment-declared" }, JSON.parse(stopped.output))
      end

      def test_snapshot_and_restore_report_their_loss_boundary_and_refuse_a_second_restore
        volume, = seeded("beta")
        directory = File.join(volume.directory, "cli-snapshot")
        snapshot = cli("snapshot", "--storage", volume.storage, "--out", directory)
        assert_equal 0, snapshot.status.exitstatus, snapshot.error
        report = JSON.parse(snapshot.output)
        assert_equal Layout::KEY_FILES.sort, report.fetch("key_files").sort
        assert_match(/every write after this snapshot is lost/, report.fetch("loss_boundary"))
        target = File.join(volume.directory, "cli-target")
        FileUtils.mkdir_p(target)
        restored = cli("restore", "--snapshot", directory, "--target", target)
        assert_equal 0, restored.status.exitstatus, restored.error
        assert_equal false, JSON.parse(restored.output).fetch("activity_preserving")
        again = cli("restore", "--snapshot", directory, "--target", target)
        assert_equal 3, again.status.exitstatus
        assert_match(/not empty/, again.error)
      end

      def test_queue_lists_unsupported_classes_as_blocked_and_never_prints_arguments
        volume, = seeded("stable")
        known = File.join(volume.directory, "known.json")
        listing = cli("known-jobs", "--image", harness.image("candidate"))
        assert_equal 0, listing.status.exitstatus, listing.error
        File.write(known, listing.output)
        assert_includes JSON.parse(listing.output), "CleanupTempFilesJob"
        refute_includes JSON.parse(listing.output), "Vendor::UnportedJob"
        queue = cli("queue", "--storage", volume.storage, "--known-classes", known)
        assert_equal 3, queue.status.exitstatus, "blocked unsupported work must make the command fail visibly"
        report = JSON.parse(queue.output)
        assert_equal 1, report.fetch("blocked_unsupported")
        blocked = report.fetch("outcomes").select { |outcome| outcome["disposition"] == "blocked-unsupported-retained" }
        assert_equal [ "Vendor::UnportedJob" ], blocked.map { |outcome| outcome["class_name"] }
        refute_includes queue.output, "M2-JOB-ARGUMENT-SENTINEL"
        assert_equal %w[failed ready scheduled], report.fetch("outcomes").select { |outcome| outcome["class_name"] == "CleanupTempFilesJob" }.map { |outcome| outcome["state"] }.sort
      end

      def test_usage_errors_exit_two
        assert_equal 2, cli("bogus").status.exitstatus
        assert_equal 2, cli("check").status.exitstatus
      end
    end
  end
end
