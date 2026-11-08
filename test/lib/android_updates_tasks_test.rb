# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../test_helpers/android_updates_test_helper"

class AndroidUpdatesTasksTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper

  setup do
    setup_android_updates
    Rails.application.load_tasks unless Rake::Task.task_defined?("android_updates:refresh")
  end
  teardown { teardown_android_updates }

  def run_task(name, *args)
    capture_io { Rake::Task[name].execute(Rake::TaskArguments.new([ :channel ], args)) }.first
  end

  test "refresh fetches now and reports what is served" do
    entry = catalog_entry(bytes: fake_apk("rake"), version_code: 8)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk("rake"))

    output = run_task("android_updates:refresh")

    assert_includes output, "release: promoted"
    assert_includes output, "release: serving 2026.11.8 (8)"
    assert_includes output, "Catalog: https://github.com"
    assert_not_includes output, "android-catalog.json"
  end

  test "refresh exits non-zero and keeps the build when the catalog fails" do
    promote_fixture(fake_apk("kept"), version_code: 3)
    stub_request(:get, CATALOG_URL).to_return(status: 502)

    output = nil
    assert_raises(SystemExit) { output = capture_io { Rake::Task["android_updates:refresh"].execute }.first }
    assert_equal 3, android_store.ready_release("release").version_code
    assert_nil output
  end

  test "status explains a server that offers nothing" do
    with_env("ANDROID_UPDATE_CHANNELS" => "none") do
      assert_includes run_task("android_updates:status"), "not offered"
    end
    assert_includes run_task("android_updates:status"), "release: nothing to serve yet"
  end

  test "forget drops one channel's cached build" do
    promote_fixture(fake_apk("forget"))

    assert_includes run_task("android_updates:forget", "release"), "Forgot the cached release build"
    assert_nil android_store.ready_release("release")
  end
end
