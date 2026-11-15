# frozen_string_literal: true

require "json"
require_relative "../lib/comparison"
require_relative "../lib/contracts"
require "minitest/autorun"
require "tmpdir"
require_relative "support/synthetic_volume"
require_relative "../lib/queue_inventory"

module Migration
  module Volume
    class QueueInventoryTest < Minitest::Test
      def setup
        @scratch = Dir.mktmpdir("m2-queue-", Scratch.root)
        @volume = SyntheticVolume.new(File.join(@scratch, "v")).build
        @volume.queue do |database|
          %w[solid_queue_scheduled_executions solid_queue_claimed_executions solid_queue_failed_executions solid_queue_blocked_executions].each do |table|
            database.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, job_id INTEGER)")
          end
          database.execute("INSERT INTO solid_queue_jobs (id, class_name, queue_name, arguments) VALUES (3, 'KnownJob', 'default', 'ARGS-SENTINEL'), (4, 'Vendor::OtherJob', 'vendor', 'ARGS-SENTINEL'), (5, 'bad name; DROP TABLE', 'x', 'ARGS-SENTINEL')")
          database.execute("INSERT INTO solid_queue_scheduled_executions (job_id) VALUES (3)")
          database.execute("INSERT INTO solid_queue_failed_executions (job_id) VALUES (4)")
          database.execute("INSERT INTO solid_queue_jobs (id, class_name, queue_name, finished_at) VALUES (6, 'KnownJob', 'default', '2026-01-01')")
          database.execute("INSERT INTO solid_queue_blocked_executions (job_id) VALUES (5)")
        end
      end

      def teardown
        FileUtils.rm_rf(@scratch)
      end

      def report(known = [ "KnownJob" ])
        QueueInventory.call(storage: @volume.storage, known_classes: known, scratch: @scratch)
      end

      def test_every_state_is_counted_and_unsupported_classes_are_reported_blocked_not_dropped
        outcomes = report.fetch("outcomes").map { |outcome| outcome.values_at("class_name", "state", "count", "disposition") }
        assert_equal [
          [ "KnownJob", "finished", 1, "finished-retained" ],
          [ "KnownJob", "ready", 1, "retained-ruby-owned" ],
          [ "KnownJob", "scheduled", 1, "retained-ruby-owned" ],
          [ "Vendor::OtherJob", "failed", 1, "blocked-unsupported-retained" ],
          [ "Vendor::UnknownJob", "ready", 1, "blocked-unsupported-retained" ],
          [ "unrecognised-name", "blocked", 1, "blocked-unsupported-retained" ]
        ], outcomes
        assert_equal 3, report.fetch("blocked_unsupported")
        assert_equal 6, report.fetch("total")
      end

      def test_a_class_known_to_the_candidate_is_no_longer_blocked
        assert_equal 1, report([ "KnownJob", "Vendor::UnknownJob" ]).fetch("outcomes").count { |outcome| outcome["class_name"] == "Vendor::UnknownJob" && outcome["disposition"] == "retained-ruby-owned" }
      end

      def test_job_arguments_and_unrecognised_names_never_reach_the_report
        text = JSON.generate(report)
        refute_includes text, "ARGS-SENTINEL"
        refute_includes text, "DROP TABLE"
      end

      def test_inventory_reads_a_copy_and_leaves_the_volume_untouched
        before = @volume.capture(@scratch)
        report
        assert_empty Comparison.call(before, @volume.capture(@scratch), allowances: Contracts.strict)
      end

      def test_a_job_without_any_execution_is_reported_unassigned_not_lost
        @volume.queue { |database| database.execute("INSERT INTO solid_queue_jobs (id, class_name, queue_name) VALUES (7, 'KnownJob', 'default')") }
        assert_equal 1, report.fetch("outcomes").count { |outcome| outcome["state"] == "unassigned" && outcome["count"] == 1 }
      end
    end
  end
end
