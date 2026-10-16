# frozen_string_literal: true

require "test_helper"
require "open3"

class SkippedTestCopTest < ActiveSupport::TestCase
  test "a helper visibility change invalidates cached discovery results" do
    with_cop_fixture do |test_path, helper_path, cache|
      File.write(helper_path, "module AgentVisibility#{Process.pid}; HIDE = false; end\n")
      File.write(test_path, <<~SOURCE)
        require "test_helper"
        require #{helper_path.to_s.inspect}
        class AgentDiscovery#{Process.pid}Test < ActiveSupport::TestCase
          def test_visible; end
          private :test_visible if AgentVisibility#{Process.pid}::HIDE
        end
      SOURCE
      report, status = lint(test_path, cache)
      assert status.success?, report.inspect
      assert_empty offenses(report)

      File.write(helper_path, File.read(helper_path).sub("false", "true"))
      report, status = lint(test_path, cache)
      assert_equal 1, status.exitstatus, report.inspect
      assert_equal 1, offenses(report).length
      assert_includes offenses(report).first.fetch("message"), "test_visible"
    end
  end

  test "private inherited test methods are reported at the local class" do
    with_cop_fixture do |test_path, helper_path, cache|
      File.write(helper_path, "module AgentInherited#{Process.pid}; def test_inherited; end; end\n")
      File.write(test_path, <<~SOURCE)
        require "test_helper"
        require #{helper_path.to_s.inspect}
        class AgentDiscovery#{Process.pid}Test < ActiveSupport::TestCase
          include AgentInherited#{Process.pid}
          private :test_inherited
        end
      SOURCE
      report, status = lint(test_path, cache)
      assert_equal 1, status.exitstatus, report.inspect
      assert_equal 1, offenses(report).length
      assert_equal 3, offenses(report).first.dig("location", "start_line")
      assert_includes offenses(report).first.fetch("message"), "test_inherited"
    end
  end

  test "public protected and private definitions follow Minitest discovery without autorun" do
    with_cop_fixture do |test_path, _, cache|
      File.write(test_path, <<~SOURCE)
        require "test_helper"
        class AgentDiscovery#{Process.pid}Test < ActiveSupport::TestCase
          def test_public; flunk "lint must not run tests"; end
          protected
          def test_protected; end
          private
          def test_private; end
          public
          def test_public_again; end
        end
      SOURCE
      report, status = lint(test_path, cache)
      assert_equal 1, status.exitstatus, report.inspect
      assert_equal 2, offenses(report).length
      assert_equal [ 5, 7 ], offenses(report).map { |offense| offense.dig("location", "start_line") }
    end
  end

  private

  def with_cop_fixture
    name = "agent_discovery_#{Process.pid}"
    test_path = Rails.root.join("test/lint/#{name}_test.rb")
    helper_path = Rails.root.join("test/test_helpers/#{name}.rb")
    Dir.mktmpdir("skipped-test-cop-") do |cache|
      yield test_path, helper_path, cache
    end
  ensure
    FileUtils.rm_f(test_path)
    FileUtils.rm_f(helper_path)
  end

  def lint(path, cache)
    output, errors, status = Open3.capture3(
      { "RAILS_ENV" => "test" },
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/SkippedTest",
      "--force-exclusion", "--format", "json", "--fail-level", "warning", "--cache-root", cache,
      path.to_s
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end
end
