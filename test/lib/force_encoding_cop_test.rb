# frozen_string_literal: true

require "test_helper"
require "open3"

class ForceEncodingCopTest < ActiveSupport::TestCase
  test "a raw force_encoding is flagged" do
    report, status = lint(<<~SOURCE)
      class LintNames
        def tagged(value)
          value.force_encoding(Encoding::UTF_8)
          value&.force_encoding("UTF-8")
        end
      end
    SOURCE

    assert_equal 1, status.exitstatus, report.inspect
    offenses = offenses(report)
    assert_equal [ 3, 4 ], offenses.map { |offense| offense.dig("location", "start_line") }
    offenses.each do |offense|
      assert_equal "warning", offense.fetch("severity")
      assert_equal "Shelfarr/ForceEncoding", offense.fetch("cop_name")
      assert_includes offense.fetch("message"), "FilenameBytes.utf8"
    end
  end

  test "force_encoding inside FilenameBytes is allowed" do
    report, status = lint(<<~SOURCE)
      class FilenameBytes
        def self.utf8(value)
          value.dup.force_encoding(Encoding::UTF_8)
        end
      end
    SOURCE

    assert status.success?, report.inspect
    assert_empty offenses(report)
  end

  test "runs the cop while the Rails process is loaded" do
    # Touch the constant before requiring RuboCop so eager load's fallback class
    # stays in place. Reloading the file would drop coverage for that branch.
    Rubocop::Cop::Shelfarr::ForceEncoding
    require "rubocop"

    flagged = exercise_cop(<<~SOURCE)
      class LintNames
        def tagged(value)
          value.force_encoding(Encoding::UTF_8)
          value&.force_encoding("UTF-8")
        end
      end

      value.force_encoding(Encoding::UTF_8)
    SOURCE
    allowed = exercise_cop(<<~SOURCE)
      class FilenameBytes
        def self.utf8(value)
          value.dup.force_encoding(Encoding::UTF_8)
        end
      end
    SOURCE

    assert_equal [ 3, 4, 8 ], flagged.map { |node| node.loc.line }
    assert_empty allowed
    harness = cop_harness
    assert_equal :warning, harness.send(:default_severity)
    dynamic_name = RuboCop::AST::Node.new(:send, [ nil, :dynamic_name ])
    assert_nil harness.send(:scope_const_name, RuboCop::AST::Node.new(:module, [ dynamic_name ]))
  end

  private

  def exercise_cop(source)
    harness = cop_harness
    processed = RuboCop::ProcessedSource.new(source, 3.3, "app/services/lint_filename_bytes.rb")
    visit = lambda do |node|
      next unless node.is_a?(RuboCop::AST::Node)

      harness.on_send(node) if node.send_type? && node.method?(:force_encoding)
      harness.on_csend(node) if node.csend_type? && node.method?(:force_encoding)
      node.children.each { |child| visit.call(child) }
    end
    visit.call(processed.ast)
    harness.offenses
  end

  def cop_harness
    Object.new.extend(Rubocop::Cop::Shelfarr::ForceEncodingBehavior).tap do |harness|
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
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/ForceEncoding",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", "app/services/lint_filename_bytes.rb", stdin_data: source
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end
end
