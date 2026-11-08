# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/android_updates_test_helper"

class AndroidUpdates::InitialRefreshTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper
  include ActiveJob::TestHelper

  setup { setup_android_updates }
  teardown { teardown_android_updates }

  def call(env = {})
    AndroidUpdates::InitialRefresh.call(configuration: AndroidUpdates::Configuration.new(env), store: android_store)
  end

  test "queues one background refresh while an enabled channel has nothing cached" do
    assert_enqueued_with(job: AndroidUpdateRefreshJob) do
      assert_equal %w[release development], call({ "ANDROID_UPDATE_CHANNELS" => "release,development" })
    end
    assert_no_requests_made
  end

  test "does nothing once every enabled channel is cached, or when disabled" do
    promote_fixture(fake_apk("boot"))

    assert_no_enqueued_jobs do
      assert_empty call
      assert_empty call({ "ANDROID_UPDATE_CHANNELS" => "none" })
      assert_empty call({ "ANDROID_UPDATE_CHANNELS" => "nightly" })
    end
  end

  def assert_no_requests_made
    assert_not_requested(:any, /.*/)
  end
end
