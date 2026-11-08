# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/android_updates_test_helper"

class AndroidAppFilesControllerTest < ActionDispatch::IntegrationTest
  include AndroidUpdatesTestHelper

  setup do
    setup_android_updates
    https!
    @bytes = fake_apk("served")
  end
  teardown { teardown_android_updates }

  def feed(channel = "release", **options)
    get "/apps/android/#{channel}.json", **options
    response.parsed_body
  end

  test "an enabled channel with nothing cached yet is not ready" do
    body = feed

    assert_response :service_unavailable
    assert_equal({ "error" => "not_ready" }, body)
    assert_equal "3600", response.headers["Retry-After"]
  end

  test "a channel that is not enabled is not offered" do
    promote_fixture(@bytes, channel: "development")

    assert_equal({ "error" => "channel_disabled" }, feed("development"))
    assert_response :not_found
    get "/apps/android/development/#{android_store.promotion('development').current.file_name}"
    assert_response :not_found
  end

  test "the feed describes the cached build with a local absolute APK URL" do
    release = promote_fixture(@bytes, version_code: 21)

    body = feed

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]
    assert_equal({
      "schema_version" => 1,
      "channel" => "release",
      "package_name" => "org.shelfarr.app",
      "version_code" => 21,
      "version_name" => "2026.11.21",
      "apk_url" => "https://www.example.com/apps/android/release/#{release.file_name}",
      "size_bytes" => @bytes.bytesize,
      "sha256" => Digest::SHA256.hexdigest(@bytes),
      "min_sdk" => 26,
      "release_notes" => "Notes for 21",
      "consumer_api_versions" => [ 1 ]
    }, body)
    assert_operator response.body.bytesize, :<, 64 * 1024
  end

  test "the feed's APK bytes match its size and SHA-256 exactly" do
    promote_fixture(@bytes)
    body = feed

    get URI.parse(body["apk_url"]).path

    assert_response :ok
    assert_equal body["size_bytes"], response.body.bytesize
    assert_equal body["sha256"], Digest::SHA256.hexdigest(response.body)
    assert_equal @bytes, response.body.b
  end

  test "the feed stays inside the deployment subpath and the feed's directory" do
    promote_fixture(@bytes)

    body = feed(env: { "SCRIPT_NAME" => "/shelfarr" })

    feed_directory = "https://www.example.com/shelfarr/apps/android/"
    assert body["apk_url"].start_with?(feed_directory), body["apk_url"]
    assert_match %r{\A#{Regexp.escape(feed_directory)}release/\d+-[0-9a-f]{64}\.apk\z}, body["apk_url"]
  end

  test "query parameters cannot point the feed or the APK elsewhere" do
    release = promote_fixture(@bytes)

    body = feed(params: { apk_url: "https://evil.example/x.apk", url: "https://evil.example/", path: "/etc/passwd" })
    assert_equal "https://www.example.com/apps/android/release/#{release.file_name}", body["apk_url"]

    get "/apps/android/release/#{release.file_name}", params: { url: "https://evil.example/x.apk", path: "/etc/passwd" }
    assert_response :ok
    assert_equal @bytes, response.body.b
  end

  test "the feed never offers a build this server's API cannot serve" do
    promote_fixture(@bytes, consumer_api_versions: [ 2 ])

    assert_equal({ "error" => "not_ready" }, feed)
  end

  test "APK responses are immutable cached bytes with download headers" do
    release = promote_fixture(@bytes)

    get "/apps/android/release/#{release.file_name}"

    assert_response :ok
    assert_equal "application/vnd.android.package-archive", response.media_type
    assert_equal %w[immutable max-age=31536000 public], response.headers["Cache-Control"].split(", ").sort
    assert_equal %("#{release.sha256}"), response.headers["ETag"]
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_equal @bytes.bytesize.to_s, response.headers["Content-Length"]
    assert_match(/attachment; filename="shelfarr-release-2026.11.10.apk"/, response.headers["Content-Disposition"])
    assert_nil response.headers["Location"]
    assert_nil response.headers["Set-Cookie"]
  end

  test "APK downloads support single byte ranges, If-Range and revalidation" do
    release = promote_fixture(@bytes)
    path = "/apps/android/release/#{release.file_name}"

    get path, headers: { "Range" => "bytes=4-11" }
    assert_response :partial_content
    assert_equal @bytes[4..11], response.body.b
    assert_equal "bytes 4-11/#{@bytes.bytesize}", response.headers["Content-Range"]

    get path, headers: { "Range" => "bytes=-5" }
    assert_equal @bytes[-5..], response.body.b

    get path, headers: { "Range" => "bytes=#{@bytes.bytesize}-" }
    assert_response :range_not_satisfiable
    assert_equal "bytes */#{@bytes.bytesize}", response.headers["Content-Range"]

    get path, headers: { "Range" => "bytes=0-1", "If-Range" => %("stale") }
    assert_response :ok
    assert_equal @bytes, response.body.b

    get path, headers: { "If-None-Match" => %("#{release.sha256}") }
    assert_response :not_modified
  end

  test "the previous build stays downloadable after a promotion; older ones do not" do
    first = promote_fixture(fake_apk(1), version_code: 1)
    second = promote_fixture(fake_apk(2), version_code: 2)

    get "/apps/android/release/#{first.file_name}"
    assert_response :ok
    assert_equal fake_apk(1), response.body.b

    promote_fixture(fake_apk(3), version_code: 3)
    get "/apps/android/release/#{first.file_name}"
    assert_response :not_found
    get "/apps/android/release/#{second.file_name}"
    assert_response :ok
  end

  test "only promoted files are served, never arbitrary paths" do
    release = promote_fixture(@bytes)
    stray = File.join(@android_root, "apks", "release", "99-#{'b' * 64}.apk")
    File.binwrite(stray, "not promoted")

    [
      "/apps/android/release/99-#{'b' * 64}.apk",
      "/apps/android/release/#{release.file_name.sub('.apk', '.json')}",
      "/apps/android/release/..%2F..%2Fstatus.json",
      "/apps/android/release/%2e%2e/%2e%2e/channels/release.json",
      "/apps/android/release/#{release.version_code}-#{release.sha256.upcase}.apk",
      "/apps/android/release/0#{release.file_name}",
      "/apps/android/../../config/master.key",
      "/apps/android/beta/#{release.file_name}"
    ].each do |path|
      get path
      assert_includes [ 404 ], response.status, path
      assert_not_equal "not promoted", response.body
    end
  end

  test "a symlink planted over a cached build is not followed" do
    release = promote_fixture(@bytes)
    secret = File.join(@android_root, "secret.txt")
    File.write(secret, "x" * @bytes.bytesize)
    path = android_store.apk_path("release", release)
    File.delete(path)
    File.symlink(secret, path)

    get "/apps/android/release/#{release.file_name}"

    assert_response :not_found
    assert_not_includes response.body, "xxxx"
  end

  test "HEAD describes feed and APK without a body or any write" do
    release = promote_fixture(@bytes)
    tree = android_tree

    assert_no_database_writes do
      head "/apps/android/release.json"
      assert_response :ok
      head "/apps/android/release/#{release.file_name}", headers: { "Range" => "bytes=0-3" }
      assert_response :ok
      assert_equal @bytes.bytesize.to_s, response.headers["Content-Length"]
      assert_empty response.body
    end
    assert_equal tree, android_tree
  end

  test "feeds and APKs ignore any session or bearer and need none" do
    release = promote_fixture(@bytes)
    sign_in_as(users(:one))

    get "/apps/android/release.json", headers: { "Authorization" => "Bearer invalid" }
    assert_response :ok
    get "/apps/android/release/#{release.file_name}", headers: { "Authorization" => "Bearer invalid" }
    assert_response :ok
    assert_nil response.headers["Set-Cookie"]
  end

  test "requests never fetch from the publisher" do
    promote_fixture(@bytes)

    feed
    feed("development")
    get "/apps/android/release/1-#{'c' * 64}.apk"

    assert_not_requested(:any, /github|githubusercontent/)
  end
end
