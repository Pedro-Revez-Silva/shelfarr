# frozen_string_literal: true

require "json"
require_relative "layout"
require_relative "safe_copy"

module Migration
  module Volume
    class QueueInventory
      STATES = { "solid_queue_ready_executions" => "ready", "solid_queue_scheduled_executions" => "scheduled", "solid_queue_claimed_executions" => "claimed",
                 "solid_queue_failed_executions" => "failed", "solid_queue_blocked_executions" => "blocked" }.freeze
      CLASS_LIMIT = 200
      NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*\z/

      Outcome = Data.define(:class_name, :state, :count, :disposition)

      def self.call(storage:, known_classes:, scratch: Scratch.root)
        new(storage, known_classes, scratch).call
      end

      def initialize(storage, known_classes, scratch)
        @storage = storage
        @known = known_classes.to_set
        @scratch = scratch
      end

      def call
        SafeCopy.open(@storage, Layout::QUEUE, scratch: @scratch) do |database|
          rows = database.execute(<<~SQL)
            SELECT j.class_name, CASE WHEN j.finished_at IS NOT NULL THEN 'finished' ELSE COALESCE(#{state_case}, 'unassigned') END, COUNT(*)
            FROM solid_queue_jobs j GROUP BY 1, 2 ORDER BY 1, 2 LIMIT #{CLASS_LIMIT}
          SQL
          outcomes = rows.map { |class_name, state, count| Outcome.new(class_name: label(class_name), state: state, count: count, disposition: disposition(class_name, state)) }
          { "outcomes" => outcomes.map { |outcome| outcome.to_h.transform_keys(&:to_s) }, "total" => outcomes.sum(&:count), "blocked_unsupported" => outcomes.select { |outcome| outcome.disposition == "blocked-unsupported-retained" }.sum(&:count) }
        end
      end

      private

      def state_case
        branches = STATES.map { |table, state| "WHEN EXISTS (SELECT 1 FROM #{table} e WHERE e.job_id = j.id) THEN '#{state}'" }
        "CASE #{branches.join(' ')} END"
      end

      def label(class_name)
        NAME_PATTERN.match?(class_name.to_s) && class_name.length <= 120 ? class_name : "unrecognised-name"
      end

      def disposition(class_name, state)
        return "finished-retained" if state == "finished"
        return "retained-ruby-owned" if @known.include?(class_name)

        "blocked-unsupported-retained"
      end
    end
  end
end
