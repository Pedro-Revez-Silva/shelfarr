# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/android_updates_test_helper"

class AndroidUpdates::StoreTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper

  setup { setup_android_updates }
  teardown { teardown_android_updates }

  test "a promoted build survives a new store instance, as after a restart" do
    bytes = fake_apk("restart")
    release = promote_fixture(bytes)

    reopened = AndroidUpdates::Store.new(@android_root)
    assert_equal release, reopened.promotion("release").current
    assert_equal release, reopened.ready_release("release")
    assert reopened.intact?("release", release)
    path = reopened.apk_path("release", release)
    assert_equal bytes, File.binread(path)
    assert_equal 0o444, File.stat(path).mode & 0o777
    assert_nil reopened.ready_release("development")
  end

  test "APK bytes are unchanged with Rails UTF-8 internal encoding" do
    previous_encoding = Encoding.default_internal
    Encoding.default_internal = Encoding::UTF_8
    bytes = (0..255).to_a.pack("C*") * 4
    release = promote_fixture(bytes)

    assert android_store.intact?("release", release)
    found, file = android_store.open_apk("release", release.file_name)
    assert_equal release, found
    assert_equal bytes, file.read
  ensure
    file&.close
    Encoding.default_internal = previous_encoding
  end

  test "keeps the build it replaces and prunes older ones" do
    first = promote_fixture(fake_apk(1), version_code: 1)
    second = promote_fixture(fake_apk(2), version_code: 2)

    promotion = android_store.promotion("release")
    assert_equal second, promotion.current
    assert_equal first, promotion.previous
    assert android_store.present?("release", first)

    third = promote_fixture(fake_apk(3), version_code: 3)
    assert_equal second, android_store.promotion("release").previous
    assert_not File.exist?(android_store.apk_path("release", first))
    assert_equal [ second.file_name, third.file_name ].sort, Dir.children(File.join(@android_root, "apks", "release")).sort
  end

  test "re-promoting the same build does not make it its own previous build" do
    bytes = fake_apk("same")
    first = promote_fixture(bytes, version_code: 4)
    promote_fixture(bytes, version_code: 4)

    assert_equal first, android_store.promotion("release").current
    assert_nil android_store.promotion("release").previous
  end

  test "opens only the current or previous build by its exact name" do
    old = promote_fixture(fake_apk("old"), version_code: 1)
    current = promote_fixture(fake_apk("new"), version_code: 2)

    [ old, current ].each do |release|
      found, file = android_store.open_apk("release", release.file_name)
      assert_equal release, found
      assert_equal release.size_bytes, file.read.bytesize
      file.close
    end
    assert_nil android_store.open_apk("release", "3-#{'a' * 64}.apk")
    assert_nil android_store.open_apk("development", current.file_name)
    assert_raises(ArgumentError) { android_store.apk_path("../../etc", current) }
  end

  test "refuses a symlink or resized file in place of a cached build" do
    release = promote_fixture(fake_apk("swap"))
    path = android_store.apk_path("release", release)
    outside = File.join(@android_root, "outside.apk")
    File.binwrite(outside, fake_apk("swap"))
    File.delete(path)
    File.symlink(outside, path)

    assert_nil android_store.open_apk("release", release.file_name)
    assert_nil android_store.ready_release("release")
    assert_not android_store.intact?("release", release)

    File.delete(path)
    File.binwrite(path, "short")
    assert_nil android_store.open_apk("release", release.file_name)
    assert_nil android_store.ready_release("release")
  end

  test "detects a damaged cached file by its checksum" do
    bytes = fake_apk("damage")
    release = promote_fixture(bytes)
    path = android_store.apk_path("release", release)
    File.chmod(0o644, path)
    File.binwrite(path, bytes.reverse)

    assert android_store.present?("release", release)
    assert_not android_store.intact?("release", release)
  end

  test "ignores unreadable or foreign channel documents" do
    promote_fixture(fake_apk("doc"))
    path = File.join(@android_root, "channels", "release.json")

    [ "{", "[]", JSON.generate("schema_version" => 2), JSON.generate(JSON.parse(File.read(path)).merge("channel" => "development")) ].each do |content|
      File.write(path, content)
      assert_equal AndroidUpdates::Store::EMPTY, android_store.promotion("release"), content
    end

    document = JSON.parse(File.read(path)).merge("channel" => "release")
    document["current"]["sha256"] = "not a digest"
    File.write(path, JSON.generate(document))
    assert_nil android_store.promotion("release").current
  end

  test "a build for an API generation this server lacks is not served" do
    release = promote_fixture(fake_apk("future"), consumer_api_versions: [ 2 ])

    assert_equal release, android_store.promotion("release").current
    assert_nil android_store.ready_release("release")
    assert_nil android_store.open_apk("release", release.file_name)
  end

  test "only one holder of the refresh lock at a time, across open files" do
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      AndroidUpdates::Store.new(@android_root).with_refresh_lock do
        entered << true
        release.pop
        :finished
      end
    end
    entered.pop

    assert_equal :busy, AndroidUpdates::Store.new(@android_root).with_refresh_lock { :ran }
    release << true
    assert_equal :finished, holder.value
    assert_equal :ran, android_store.with_refresh_lock { :ran }
  end

  test "staging files are removed on failure and on the next refresh" do
    assert_raises(RuntimeError) { android_store.stage { |file| file.write("partial") ; raise "interrupted" } }
    staging = File.join(@android_root, "staging")
    assert_empty Dir.children(staging)

    path = android_store.stage { |file| file.write("abandoned") }
    assert File.exist?(path)
    android_store.clear_staging!
    assert_not File.exist?(path)
  end

  test "status documents are written atomically and read back" do
    android_store.write_status("checked_at" => "2026-11-08T10:00:00Z", "channels" => {})

    assert_equal "2026-11-08T10:00:00Z", android_store.status["checked_at"]
    assert_equal [ "status.json" ], Dir.children(@android_root).grep(/status/)
  end

  test "forgetting a channel removes its promotion and files" do
    promote_fixture(fake_apk("forget"))
    android_store.forget!("release")

    assert_nil android_store.promotion("release").current
    assert_not File.exist?(File.join(@android_root, "apks", "release"))
  end
end
