# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/android_updates_test_helper"

class AndroidUpdates::RefresherTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper

  setup do
    setup_android_updates
    @now = Time.utc(2026, 11, 8, 12)
  end
  teardown { teardown_android_updates }

  def refresher(env = {}, fetcher: nil)
    AndroidUpdates::Refresher.new(
      configuration: AndroidUpdates::Configuration.new(env), store: android_store, fetcher: fetcher, clock: -> { @now }
    )
  end

  def refresh(env = {}, force: true)
    refresher(env).call(force: force)
  end

  def staging_children
    staging = File.join(@android_root, "staging")
    File.exist?(staging) ? Dir.children(staging) : []
  end

  test "caches the highest compatible build for each enabled channel" do
    old = catalog_entry(bytes: fake_apk(10), version_code: 10)
    best = catalog_entry(bytes: fake_apk(12), version_code: 12)
    newer_but_incompatible = catalog_entry(bytes: fake_apk(14), version_code: 14, consumer_api_versions: [ 2 ])
    development = catalog_entry(bytes: fake_apk(30), channel: "development", version_code: 30)
    stub_catalog([ old, newer_but_incompatible, best, development ])
    stub_apk(best, fake_apk(12))

    outcome = refresh

    assert outcome.ok?
    assert_equal({ "release" => { result: "promoted", version_code: 12 } }, outcome.channels)
    current = android_store.ready_release("release")
    assert_equal 12, current.version_code
    assert_equal fake_apk(12), File.binread(android_store.apk_path("release", current))
    assert_nil android_store.ready_release("development")
    assert_not_requested(:get, development["apk_url"])
    assert_not_requested(:get, newer_but_incompatible["apk_url"])
    assert_empty staging_children
    assert_equal "2026-11-08T12:00:00Z", android_store.status.dig("channels", "release", "succeeded_at")
  end

  test "development builds are cached only when that channel is enabled" do
    development = catalog_entry(bytes: fake_apk(30), channel: "development", version_code: 30)
    release = catalog_entry(bytes: fake_apk(11), version_code: 11)
    stub_catalog([ development, release ])
    stub_apk(development, fake_apk(30))
    stub_apk(release, fake_apk(11))

    outcome = refresh({ "ANDROID_UPDATE_CHANNELS" => "release,development" })

    assert outcome.ok?
    assert_equal 30, android_store.ready_release("development").version_code
    assert_equal "org.shelfarr.app.debug", android_store.ready_release("development").package_name
    assert_equal 11, android_store.ready_release("release").version_code
  end

  test "a download that fails verification keeps the previous good build" do
    good = promote_fixture(fake_apk(10), version_code: 10)
    newer = catalog_entry(bytes: fake_apk(11), version_code: 11)
    stub_catalog([ newer ])

    { "integrity_mismatch" => { status: 200, body: fake_apk("tampered")[0, fake_apk(11).bytesize] },
      "integrity_mismatch_short" => { status: 200, body: fake_apk(11)[0..-2] },
      "download_too_large" => { status: 200, body: fake_apk(11) + "extra" },
      "download_http_status" => { status: 500, body: "" } }.each do |expected, response|
      stub_request(:get, newer["apk_url"]).to_return(response)

      outcome = refresh

      assert_not outcome.ok?, expected
      assert_equal expected.delete_suffix("_short"), outcome.channels.dig("release", :error)
      assert_equal good, android_store.ready_release("release")
      assert android_store.intact?("release", good)
      assert_empty staging_children
      assert_not File.exist?(File.join(@android_root, "apks", "release", AndroidUpdates::Release.from_h(newer).file_name))
    end
    assert_equal "download_http_status", android_store.status.dig("channels", "release", "error")
  end

  test "a network failure during the APK download keeps the previous good build" do
    good = promote_fixture(fake_apk(10), version_code: 10)
    newer = catalog_entry(bytes: fake_apk(11), version_code: 11)
    stub_catalog([ newer ])
    stub_request(:get, newer["apk_url"]).to_timeout

    assert_equal "download_network", refresh.channels.dig("release", :error)
    assert_equal good, android_store.ready_release("release")
  end

  test "an unavailable or malformed catalog keeps the previous good build" do
    good = promote_fixture(fake_apk(10), version_code: 10)

    {
      "catalog_http_status" => -> { stub_request(:get, CATALOG_URL).to_return(status: 503) },
      "catalog_network" => -> { stub_request(:get, CATALOG_URL).to_timeout },
      "catalog_invalid" => -> { stub_request(:get, CATALOG_URL).to_return(status: 200, body: "{nope") }
    }.each do |category, stub|
      WebMock.reset!
      stub.call

      outcome = refresh

      assert_equal({ "release" => { result: "kept", error: category } }, outcome.channels)
      assert_equal good, android_store.ready_release("release")
      assert_equal category, android_store.status.dig("channels", "release", "error")
    end
  end

  test "never steps back to a lower version code than the promoted build" do
    promoted = promote_fixture(fake_apk(12), version_code: 12)
    stub_catalog([ catalog_entry(bytes: fake_apk(10), version_code: 10) ])

    outcome = refresh

    assert outcome.ok?
    assert_equal "catalog_older", outcome.channels.dig("release", :note)
    assert_equal promoted, android_store.ready_release("release")
  end

  test "a reused version code with different bytes is a conflict, not an update" do
    promoted = promote_fixture(fake_apk(12), version_code: 12)
    stub_catalog([ catalog_entry(bytes: fake_apk("other"), version_code: 12) ])

    assert_equal "version_conflict", refresh.channels.dig("release", :error)
    assert_equal promoted, android_store.ready_release("release")
  end

  test "conflicting catalog entries for one version code are refused" do
    stub_catalog([
      catalog_entry(bytes: fake_apk("a"), version_code: 12),
      catalog_entry(bytes: fake_apk("b"), version_code: 12)
    ])

    assert_equal "version_conflict", refresh.channels.dig("release", :error)
    assert_nil android_store.ready_release("release")
  end

  test "an already cached, intact build is not downloaded again" do
    promoted = promote_fixture(fake_apk(12), version_code: 12)
    entry = catalog_entry(bytes: fake_apk(12), version_code: 12)
    stub_catalog([ entry ])

    assert refresh.ok?
    assert_not_requested(:get, entry["apk_url"])
    assert_equal promoted, android_store.ready_release("release")
  end

  test "a damaged cached build is replaced by a fresh verified copy" do
    promoted = promote_fixture(fake_apk(12), version_code: 12)
    path = android_store.apk_path("release", promoted)
    File.chmod(0o644, path)
    File.binwrite(path, fake_apk(12).reverse)
    entry = catalog_entry(bytes: fake_apk(12), version_code: 12)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk(12))

    assert_equal "promoted", refresh.channels.dig("release", :result)
    assert android_store.intact?("release", android_store.ready_release("release"))
  end

  test "no compatible build leaves the channel empty with a reason" do
    stub_catalog([ catalog_entry(bytes: fake_apk(1), consumer_api_versions: [ 9 ]) ])

    assert_equal "no_compatible_release", refresh.channels.dig("release", :error)
    assert_nil android_store.ready_release("release")
  end

  test "a promoted build this server can no longer serve does not block a compatible one" do
    promote_fixture(fake_apk(20), version_code: 20, consumer_api_versions: [ 2 ])
    entry = catalog_entry(bytes: fake_apk(15), version_code: 15)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk(15))

    assert_equal "promoted", refresh.channels.dig("release", :result)
    assert_equal 15, android_store.ready_release("release").version_code
  end

  test "a scheduled refresh shortly after another one is skipped; a forced one is not" do
    entry = catalog_entry(bytes: fake_apk(12), version_code: 12)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk(12))
    assert refresh.ok?

    @now += 1.minute
    assert_equal :skipped, refresh(force: false).status
    assert_requested(:get, CATALOG_URL, times: 1)

    assert_equal :ok, refresh(force: true).status
    @now += AndroidUpdates::Refresher::MIN_INTERVAL
    assert_equal :ok, refresh(force: false).status
    assert_requested(:get, CATALOG_URL, times: 3)
  end

  test "concurrent refreshes promote once; the other reports busy" do
    entry = catalog_entry(bytes: fake_apk(12), version_code: 12)
    stub_catalog([ entry ])
    stub_apk(entry, fake_apk(12))
    started = Queue.new
    proceed = Queue.new
    slow = AndroidUpdates::Fetcher.new(AndroidUpdates::Configuration.new({}).source_policy)
    slow.define_singleton_method(:catalog) do |*args, **options|
      started << true
      proceed.pop
      super(*args, **options)
    end

    first = Thread.new { refresher(fetcher: slow).call(force: true) }
    started.pop
    second = refresher.call(force: true)
    proceed << true

    assert_equal :busy, second.status
    assert first.value.ok?
    assert_requested(:get, entry["apk_url"], times: 1)
    assert_equal 12, android_store.ready_release("release").version_code
  end

  test "disabled or misconfigured servers make no requests" do
    assert_equal :disabled, refresh({ "ANDROID_UPDATE_CHANNELS" => "none" }).status
    assert_equal :misconfigured, refresh({ "ANDROID_UPDATE_CATALOG_URL" => "http://insecure.example/c.json" }).status
    assert_not_requested(:get, CATALOG_URL)
  end

  test "a custom publisher's builds must come from its own origin" do
    custom = "https://updates.example.org/shelfarr/catalog.json"
    inside = catalog_entry(bytes: fake_apk(5), version_code: 5, apk_url: "https://updates.example.org/files/5.apk")
    outside = catalog_entry(bytes: fake_apk(9), version_code: 9, apk_url: "https://cdn.example.net/9.apk")
    stub_catalog([ inside, outside ], url: custom)
    stub_apk(inside, fake_apk(5))

    outcome = refresh({ "ANDROID_UPDATE_CATALOG_URL" => custom })

    assert outcome.ok?
    assert_equal 5, android_store.ready_release("release").version_code
    assert_not_requested(:get, outside["apk_url"])
    assert_equal "https://updates.example.org", android_store.status["source"]
  end

  test "a storage failure keeps the previous build and is reported" do
    good = promote_fixture(fake_apk(10), version_code: 10)
    newer = catalog_entry(bytes: fake_apk(11), version_code: 11)
    stub_catalog([ newer ])
    stub_apk(newer, fake_apk(11))
    store = android_store
    store.define_singleton_method(:promote!) { |*| raise Errno::ENOSPC }

    outcome = AndroidUpdates::Refresher.new(
      configuration: AndroidUpdates::Configuration.new({}), store: store, clock: -> { @now }
    ).call(force: true)

    assert_equal "storage_error", outcome.channels.dig("release", :error)
    assert_equal good, android_store.ready_release("release")
    assert_empty staging_children
  end
end
