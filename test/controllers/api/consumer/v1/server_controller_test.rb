# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/android_updates_test_helper"

class API::Consumer::V1::ServerControllerTest < ActionDispatch::IntegrationTest
  include AndroidUpdatesTestHelper

  setup { setup_android_updates }
  teardown { teardown_android_updates }

  test "describes the server and its release channel without a bearer" do
    get "/api/consumer/v1/server.json"

    assert_response :ok
    assert_equal({
      "schema_version" => 1,
      "server_version" => File.read(Rails.root.join("VERSION")).strip,
      "consumer_api_versions" => [ 1 ],
      "android" => {
        "release" => {
          "feed_url" => "/apps/android/release.json",
          "download_page_url" => "/apps/android"
        }
      }
    }, response.parsed_body)
    assert_nil response.headers["Set-Cookie"]
  end

  test "advertises development only when it is enabled" do
    with_env("ANDROID_UPDATE_CHANNELS" => "release,development") do
      get "/api/consumer/v1/server.json"
    end

    assert_equal({
      "feed_url" => "/apps/android/development.json",
      "download_page_url" => "/apps/android?channel=development"
    }, response.parsed_body.dig("android", "development"))
  end

  test "keeps every advertised path inside the deployment subpath" do
    with_env("ANDROID_UPDATE_CHANNELS" => "development,release") do
      get "/api/consumer/v1/server.json", env: { "SCRIPT_NAME" => "/shelfarr" }
    end

    urls = response.parsed_body["android"].values.flat_map(&:values)
    assert_equal 4, urls.size
    urls.each { |url| assert url.start_with?("/shelfarr/apps/android"), url }
  end

  test "offers no channels when Android builds are disabled or misconfigured" do
    [ { "ANDROID_UPDATE_CHANNELS" => "none" }, { "ANDROID_UPDATE_CATALOG_URL" => "http://insecure.example/c.json" } ].each do |env|
      with_env(env) { get "/api/consumer/v1/server.json" }

      assert_response :ok
      assert_equal({}, response.parsed_body["android"])
    end
  end

  test "ignores credentials, makes no writes and never contacts the publisher" do
    _token, raw = APIToken.issue!(name: "Phone", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)

    assert_no_database_writes do
      get "/api/consumer/v1/server.json", headers: { "Authorization" => "Bearer #{raw}" }
      assert_response :ok
      head "/api/consumer/v1/server.json"
      assert_response :ok
    end
    assert_not_requested(:any, /github/)
    assert_not_includes response.body, users(:one).username.to_s
  end
end
