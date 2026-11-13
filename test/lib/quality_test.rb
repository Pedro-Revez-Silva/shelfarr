# frozen_string_literal: true

require "test_helper"
load Rails.root.join("bin/quality")

class QualityTest < ActiveSupport::TestCase
  ScanStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus == 0
    end
  end

  test "Brakeman succeeds only after a successful scan command" do
    invocation = nil
    _, errors = capture_io do
      Open3.stub(:capture2e, ->(*arguments) { invocation = arguments; [ "", ScanStatus.new(0) ] }) do
        assert Quality.run_brakeman
      end
    end

    assert_equal [ { "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s },
      "bin/brakeman", "--quiet", "--no-pager", "--exit-on-warn", "--exit-on-error" ], invocation
    assert_includes errors, "Running Brakeman"
  end

  test "an outdated scanner notice cannot substitute for a scan" do
    assert_scan_failure(5, "Brakeman 7.1.1 is not the latest version 8.1.0\n")
  end

  test "scanner failure without output fails the gate" do
    assert_scan_failure(1, "")
  end

  test "scanner warnings fail the gate and remain visible" do
    assert_scan_failure(3, "High confidence warning: unsafe file access\n")
  end

  test "scanner errors fail the gate and remain visible" do
    assert_scan_failure(7, "Could not parse a source file\n")
  end

  test "a missing scanner fails the gate" do
    _, errors = capture_io do
      Open3.stub(:capture2e, ->(*) { raise Errno::ENOENT, "bin/brakeman" }) do
        assert_not Quality.run_brakeman
      end
    end

    assert_includes errors, "Brakeman failed"
    assert_includes errors, "bin/brakeman"
  end

  test "commit cannot turn a fast-check failure into a coverage success" do
    Quality.stub(:run_fast, 1) do
      Quality.stub(:run_coverage, -> { flunk "coverage must not hide the failed check" }) do
        assert_equal 1, Quality.run_commit([])
      end
    end
  end

  test "deep cannot turn a push-check failure into a mutation-test success" do
    Quality.stub(:run_push, 1) do
      Quality.stub(:all_mutant_expressions, -> { flunk "a failed gate must stop deep checks" }) do
        assert_not Quality.run_deep
      end
    end
  end

  test "commit and deep retain their documented success return values" do
    Quality.stub(:run_fast, 0) do
      Quality.stub(:run_coverage, true) { assert_equal 0, Quality.run_commit([]) }
      Quality.stub(:run_coverage, false) { assert_equal 1, Quality.run_commit([]) }
    end
    Quality.stub(:run_push, 0) do
      Quality.stub(:all_mutant_expressions, []) { assert Quality.run_deep }
      Quality.stub(:all_mutant_expressions, [ "SearchResult#safe_info_url" ]) do
        Quality.stub(:run_mutant_command, false) { assert_not Quality.run_deep }
        Quality.stub(:run_mutant_command, true) { assert Quality.run_deep }
      end
    end
  end

  private

  def assert_scan_failure(exitstatus, output)
    _, errors = capture_io do
      Open3.stub(:capture2e, [ output, ScanStatus.new(exitstatus) ]) do
        assert_not Quality.run_brakeman
      end
    end

    assert_includes errors, "Brakeman failed (exit #{exitstatus})"
    assert_includes errors, output unless output.empty?
  end
end
