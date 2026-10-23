# frozen_string_literal: true

require "test_helper"
require "open3"

class SelfEnqueueCopTest < ActiveSupport::TestCase
  test "a raw self perform_later is flagged" do
    report, status = lint(<<~SOURCE)
      class LintChainJob < ApplicationJob
        class << self
          def ensure_running!
            perform_later
          end
        end

        def perform
          self.class.set(wait: 1.second).perform_later
          LintChainJob.perform_later
        end

        def self.schedule
          set(wait: 1.second).perform_later
        end
      end
    SOURCE

    assert_equal 1, status.exitstatus, report.inspect
    offenses = offenses(report)
    assert_equal [ 4, 9, 10, 14 ], offenses.map { |offense| offense.dig("location", "start_line") }
    offenses.each do |offense|
      assert_equal "warning", offense.fetch("severity")
      assert_equal "Shelfarr/SelfEnqueue", offense.fetch("cop_name")
      assert_includes offense.fetch("message"), "config/recurring.yml"
      assert_includes offense.fetch("message"), "SingleChain.enqueue"
    end
  end

  test "SingleChain.enqueue and another class are allowed" do
    report, status = lint(<<~SOURCE)
      module SingleChain
        class << self
          def enqueue(job_class, *)
            job_class.set(wait: 1.second).perform_later
          end
        end
      end

      class LintChainJob < ApplicationJob
        def perform
          OtherJob.perform_later
          SingleChain.enqueue(self.class)
        end
      end
    SOURCE

    assert status.success?, report.inspect
    assert_empty offenses(report)
  end

  test "runs the cop while the Rails process is loaded" do
    # Touch the constant before requiring RuboCop so eager load's fallback class
    # stays in place. Reloading the file would drop coverage for that branch.
    Rubocop::Cop::Shelfarr::SelfEnqueue
    require "rubocop"

    flagged = exercise_cop(<<~SOURCE)
      class LintChainJob < ApplicationJob
        class << self
          def ensure_running!
            perform_later
          end
        end

        def perform
          self.perform_later
          self.class.set(wait: 1.second).perform_later
          LintChainJob.perform_later
          other.perform_later
        end

        def self.schedule
          set(wait: 1.second).perform_later
        end
      end

      perform_later
    SOURCE
    allowed = exercise_cop(<<~SOURCE)
      module SingleChain
        class << self
          def enqueue(job_class, *)
            job_class.set(wait: 1.second).perform_later
          end
        end
      end
    SOURCE

    assert_equal [ 4, 10, 11, 16 ], flagged.map { |node| node.loc.line }
    assert_empty allowed
    harness = cop_harness
    assert_equal :warning, harness.send(:default_severity)
    dynamic_name = RuboCop::AST::Node.new(:send, [ nil, :dynamic_name ])
    assert_nil harness.send(:scope_const_name, RuboCop::AST::Node.new(:module, [ dynamic_name ]))
  end

  private

  def exercise_cop(source)
    harness = cop_harness
    processed = RuboCop::ProcessedSource.new(source, 3.3, "app/jobs/lint_self_enqueue_job.rb")
    visit = lambda do |node|
      next unless node.is_a?(RuboCop::AST::Node)

      harness.on_send(node) if node.send_type? && node.method?(:perform_later)
      node.children.each { |child| visit.call(child) }
    end
    visit.call(processed.ast)
    harness.offenses
  end

  def cop_harness
    Object.new.extend(Rubocop::Cop::Shelfarr::SelfEnqueueBehavior).tap do |harness|
      offenses = []
      harness.define_singleton_method(:offenses) { offenses }
      harness.define_singleton_method(:add_offense) do |node, message:|
        offenses << node
        message
      end
    end
  end

  def lint(source)
    output, errors, status = Open3.capture3(
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/SelfEnqueue",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", "app/jobs/lint_self_enqueue_job.rb", stdin_data: source
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end
end
