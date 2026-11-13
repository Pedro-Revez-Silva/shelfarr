# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/android_updates_test_helper"

class AndroidUpdateRefreshJobTest < ActiveJob::TestCase
  include AndroidUpdatesTestHelper

  setup { setup_android_updates }
  teardown { teardown_android_updates }

  test "refreshes the cache from the catalog" do
    entry = catalog_entry(bytes: fake_apk("job"), version_code: 7)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk("job"))

    assert_equal :ok, AndroidUpdateRefreshJob.perform_now
    assert_equal 7, android_store.ready_release("release").version_code
  end

  test "a scheduled run soon after another is skipped unless forced" do
    stub_catalog([])
    AndroidUpdateRefreshJob.perform_now

    assert_equal :skipped, AndroidUpdateRefreshJob.perform_now
    assert_equal :ok, AndroidUpdateRefreshJob.perform_now(force: true)
  end

  test "a disabled server does nothing" do
    with_env("ANDROID_UPDATE_CHANNELS" => "none") do
      assert_equal :disabled, AndroidUpdateRefreshJob.perform_now
    end
  end
end
