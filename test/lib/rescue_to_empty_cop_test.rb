# frozen_string_literal: true

require "test_helper"
require "open3"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/shelfarr/rescue_to_empty")

class RescueToEmptyCopTest < ActiveSupport::TestCase
  EMPTY_RESCUE = <<~SOURCE
    class LintRemote
      def tagged
        fetch
      rescue StandardError
        []
      end

      def missing
        fetch
      rescue StandardError
        nil
      end

      def denied
        fetch
      rescue StandardError
        false
      end

      def opened
        fetch
      rescue StandardError
        true
      end

      def modifier
        fetch
      rescue StandardError => error
        return [] if ready?
        RemoteResult::Failed.new(error)
      end

      def bare
        fetch
      rescue StandardError => error
        return
      end

      def implicit
        fetch
      rescue StandardError
      end

      def wrapped
        fetch
      rescue StandardError
        begin
          nil
        end
      end
    end
  SOURCE

  CALLER_RESCUE = <<~SOURCE
    class LintRemote
      def widen(result)
        result.empty?
      end

      def show
        failure = RemoteResult::Failed.new(StandardError.new("down"))
        failure.empty?
        failure.to_s
        failure.to_str
        "tags \#{failure}"
        "prefix " + failure
        failure + " suffix"
        other + failure
        failure&.empty?
      end

      def direct
        RemoteResult::Failed.new(StandardError.new("down")).empty?
      end

      def kept(result)
        case result
        when RemoteResult::Failed
          :keep
        else
          result.empty?
        end
      end

      def checked(result)
        return if RemoteResult.failed?(result) || result.is_a?(RemoteResult::Failed)

        result.to_s
      end

      def listed(result)
        result.empty? if result.is_a?(Array)
      end

      def typed(result)
        result.is_a?(kind)
      end
    end
  SOURCE

  test "a rescue that returns an empty value is flagged" do
    report, status = lint(EMPTY_RESCUE)
    assert_equal 1, status.exitstatus, report.inspect
    offenses = offenses(report)
    assert_equal [ 5, 11, 17, 23, 29, 36, 41, 48 ], offenses.map { |offense| offense.dig("location", "start_line") }
    offenses.each do |offense|
      message = offense.fetch("message")
      assert_equal "warning", offense.fetch("severity")
      assert_equal "Shelfarr/RescueToEmpty", offense.fetch("cop_name")
      assert_includes message, "Failed"
      assert_includes message, "[]"
      assert_includes message, "nil"
      assert_includes message, "false"
      assert_includes message, "true"
      assert_includes message, "Match"
    end
    assert_equal 8, exercise_cop(EMPTY_RESCUE).size
  end

  test "a rescue that returns Failed is clean" do
    source = <<~SOURCE
      class LintRemote
        def tagged
          fetch
        rescue StandardError => error
          RemoteResult::Failed.new(error)
        end
      end
    SOURCE

    report, status = lint(source)
    assert_equal 0, status.exitstatus, report.inspect
    assert_empty offenses(report)
    assert_empty exercise_cop(source)
  end

  test "empty? and string conversion without a Failed match are flagged" do
    report, status = lint(CALLER_RESCUE)
    assert_equal 1, status.exitstatus, report.inspect
    lines = offenses(report).map { |offense| offense.dig("location", "start_line") }
    assert_includes lines, 3
    assert_includes lines, 8
    assert_includes lines, 9
    assert_includes lines, 10
    assert_includes lines, 11
    assert_includes lines, 12
    assert_includes lines, 13
    assert_includes lines, 15
    assert_includes lines, 19
    assert_not_includes lines, 14
    assert_not_includes lines, 27
    assert_not_includes lines, 34
    assert_not_includes lines, 38
    offenses(report).each do |offense|
      message = offense.fetch("message")
      assert_includes message, "Failed"
      assert_includes message, "Match"
    end

    exercised = exercise_cop(CALLER_RESCUE)
    assert_includes exercised.map { |node| node.loc.line }, 3
    assert_equal :warning, cop_harness.send(:default_severity)
  end

  private

  def exercise_cop(source)
    harness = cop_harness
    processed = RuboCop::ProcessedSource.new(source, 3.3, "app/services/lint_remote.rb")
    visit = lambda do |node|
      next unless node.is_a?(RuboCop::AST::Node)

      harness.on_resbody(node) if node.resbody_type?
      harness.on_send(node) if node.send_type?
      harness.on_csend(node) if node.csend_type?
      harness.on_dstr(node) if node.dstr_type?
      node.children.each { |child| visit.call(child) }
    end
    visit.call(processed.ast)
    harness.offenses
  end

  def cop_harness
    Object.new.extend(Rubocop::Cop::Shelfarr::RescueToEmptyBehavior).tap do |harness|
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
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/RescueToEmpty",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", "app/services/lint_remote.rb", stdin_data: source
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end
end
