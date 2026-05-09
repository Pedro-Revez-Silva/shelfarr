# frozen_string_literal: true

require "test_helper"

class UpdateCheckJobTest < ActiveJob::TestCase
  test "logs available update details" do
    result = UpdateCheckerService::Result.new(
      current_version: "1.0.0",
      latest_version: "1.1.0",
      update_available: true,
      latest_message: "New release",
      latest_date: Time.current,
      release_url: "https://example.test/release"
    )

    UpdateCheckerService.stub(:check, result) do
      assert_nothing_raised { UpdateCheckJob.perform_now }
    end
  end

  test "logs when no update is available" do
    result = UpdateCheckerService::Result.new(
      current_version: "1.0.0",
      latest_version: "1.0.0",
      update_available: false,
      latest_message: nil,
      latest_date: nil,
      release_url: nil
    )

    UpdateCheckerService.stub(:check, result) do
      assert_nothing_raised { UpdateCheckJob.perform_now }
    end
  end
end
