# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TimeZoneConfigTest < ActiveSupport::TestCase
  test "uses TZ for the Rails application time zone" do
    output, error, status = Open3.capture3(
      { "RAILS_ENV" => "test", "TZ" => "America/New_York" },
      RbConfig.ruby,
      "bin/rails",
      "runner",
      "print Time.zone.name",
      chdir: Rails.root.to_s
    )

    assert status.success?, error
    assert_equal "America/New_York", output
  end
end
