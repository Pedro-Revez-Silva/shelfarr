# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/android_updates_test_helper"

class AndroidAppsControllerTest < ActionDispatch::IntegrationTest
  include AndroidUpdatesTestHelper

  setup do
    setup_android_updates
    https!
  end
  teardown { teardown_android_updates }

  test "is public and explains that the build is not ready yet" do
    get "/apps/android"

    assert_response :ok
    assert_select "h1", /Shelfarr for Android/
    assert_select "[role=status]", /isn't ready on this server yet/
    assert_select "#android-download", false
    assert_not_includes response.body, "android_updates:refresh"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "offers the download, then a connect link carrying only the server address" do
    release = promote_fixture(fake_apk("page"), version_code: 33)

    get "/apps/android"

    assert_response :ok
    assert_select "#android-download[href=?]", "/apps/android/release/#{release.file_name}", text: /Download Shelfarr 2026.11.33/
    assert_select "#android-open[href=?]", "shelfarr://connect?server=https%3A%2F%2Fwww.example.com", text: "Open Shelfarr"
    assert_operator response.body.index("android-download"), :<, response.body.index("android-open")
    assert_includes response.body, "tap <strong>Done</strong>, return to this page and tap <strong>Open Shelfarr</strong>"
    assert_includes response.body, "can't tell which server it was downloaded from"
    assert_includes response.body, "Don't uninstall the app"
    assert_not_includes response.body, "Development build"
  end

  test "the connect link includes the deployment subpath and a non-default port" do
    promote_fixture(fake_apk("subpath"))
    host! "books.example.org:8443"

    get "/apps/android", env: { "SCRIPT_NAME" => "/shelfarr" }

    assert_select "#android-open[href=?]", "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%3A8443%2Fshelfarr"
    assert_select "#android-download[href^=?]", "/shelfarr/apps/android/release/"
  end

  test "without HTTPS it gives no connect link and explains why" do
    promote_fixture(fake_apk("http"))
    https!(false)

    get "/apps/android"

    assert_select "#android-download"
    assert_select "#android-open", false
    assert_includes response.body, "isn't open over HTTPS"
  end

  test "the development page is labelled and serves the development build when enabled" do
    with_env("ANDROID_UPDATE_CHANNELS" => "release,development") do
      release = promote_fixture(fake_apk("dev"), channel: "development", version_code: 40)

      get "/apps/android", params: { channel: "development" }

      assert_response :ok
      assert_select "h1", /Development build/
      assert_select "#android-download[href=?]", "/apps/android/development/#{release.file_name}"
      assert_includes response.body, "separate app next to the regular one"
    end
  end

  test "a channel the server does not offer says so" do
    get "/apps/android", params: { channel: "development" }

    assert_response :not_found
    assert_includes response.body, "doesn't offer the development Android build"
    assert_select "a[href=?]", "/apps/android", text: "Get the regular Android app"

    get "/apps/android", params: { channel: "nightly" }
    assert_response :not_found
    get "/apps/android?channel[]=release"
    assert_response :not_found
  end

  test "administrators see why a build is missing and how to retry" do
    android_store.write_status("checked_at" => "2026-11-08T10:00:00Z", "channels" => { "release" => { "error" => "catalog_network" } })
    sign_in_as(users(:two))
    assert users(:two).admin?

    get "/apps/android"
    assert_includes response.body, "catalog_network"
    assert_includes response.body, "bin/rails android_updates:refresh"

    sign_out
    sign_in_as(users(:one))
    get "/apps/android"
    assert_not_includes response.body, "catalog_network"
  end

  test "administrators see a configuration problem" do
    sign_in_as(users(:two))

    with_env("ANDROID_UPDATE_CHANNELS" => "beta") { get "/apps/android" }

    assert_response :not_found
    assert_includes response.body, "ANDROID_UPDATE_CHANNELS may only list"
  end

  test "HEAD renders nothing new and writes nothing" do
    promote_fixture(fake_apk("head"))
    tree = android_tree

    assert_no_database_writes do
      head "/apps/android"
      assert_response :ok
    end
    assert_equal tree, android_tree
  end

  test "the profile and the reader library link to the install page" do
    sign_in_as(users(:one))

    get profile_path
    assert_select "a[href=?]", "/apps/android", text: "Get the Android app"

    get consumer_library_path
    assert_select "a[href=?]", "/apps/android", text: "Get the Android app"

    with_env("ANDROID_UPDATE_CHANNELS" => "development") do
      get profile_path
      assert_select "a[href=?]", "/apps/android?channel=development", text: "Get the Android app"
    end

    with_env("ANDROID_UPDATE_CHANNELS" => "none") do
      get profile_path
      assert_select "a", text: "Get the Android app", count: 0
    end
  end
end
