# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TimeZoneConfigTest < ActiveSupport::TestCase
  test "uses TZ for the Rails application time zone" do
    output, error, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "TZ" => "America/New_York",
        # This boot probe is part of the parent test run, not a second coverage
        # process. Inheriting COVERAGE would make SimpleCov write to the shared
        # resultset and append its report to the value asserted below.
        "COVERAGE" => nil
      },
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "print Time.zone.name",
      chdir: Rails.root.to_s
    )

    assert status.success?, error
    assert_equal "America/New_York", output
  end

  test "renders timestamps in the configured timezone" do
    output, error, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "TZ" => "America/New_York",
        "COVERAGE" => nil
      },
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "t = Time.utc(2026, 8, 31, 20, 0, 0); print t.in_time_zone.strftime('%Z %z')",
      chdir: Rails.root.to_s
    )

    assert status.success?, error
    # America/New_York in August is EDT (Eastern Daylight Time), UTC-4
    assert_match(/EDT -0400/, output, "Timestamp should be rendered in America/New_York timezone (EDT -0400)")
  end

  test "defaults to UTC when TZ is not set" do
    output, error, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "TZ" => nil,
        "COVERAGE" => nil
      },
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "print Time.zone.name",
      chdir: Rails.root.to_s
    )

    assert status.success?, error
    assert_equal "UTC", output
  end

  test "falls back to UTC for invalid TZ values" do
    output, error, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "TZ" => "Invalid/Timezone",
        "COVERAGE" => nil
      },
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "print Time.zone.name",
      chdir: Rails.root.to_s
    )

    assert status.success?, error
    assert_equal "UTC", output, "Should fall back to UTC for invalid timezone"
  end
end
