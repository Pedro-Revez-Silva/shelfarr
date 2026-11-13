# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/android_updates_test_helper"

class AndroidUpdates::CatalogTest < ActiveSupport::TestCase
  include AndroidUpdatesTestHelper

  setup do
    @policy = AndroidUpdates::Configuration.new({}).source_policy
    @bytes = fake_apk("catalog")
  end

  def parse(entries)
    AndroidUpdates::Catalog.parse(catalog_json(entries), policy: @policy)
  end

  test "reads every field of a valid entry" do
    catalog = parse([ catalog_entry(bytes: @bytes, version_code: 12) ])
    release = catalog.releases.sole

    assert_equal "release", release.channel
    assert_equal "org.shelfarr.app", release.package_name
    assert_equal 12, release.version_code
    assert_equal "2026.11.12", release.version_name
    assert_equal @bytes.bytesize, release.size_bytes
    assert_equal Digest::SHA256.hexdigest(@bytes), release.sha256
    assert_equal 26, release.min_sdk
    assert_equal "Notes for 12", release.release_notes
    assert_equal [ 1 ], release.consumer_api_versions
    assert release.compatible?
    assert_equal "12-#{release.sha256}.apk", release.file_name
    assert_equal 0, catalog.skipped
  end

  test "keeps channels and packages apart" do
    catalog = parse([
      catalog_entry(bytes: @bytes, channel: "release"),
      catalog_entry(bytes: @bytes, channel: "development", version_code: 30)
    ])

    assert_equal [ 10 ], catalog.for_channel("release", "org.shelfarr.app").map(&:version_code)
    assert_equal [ 30 ], catalog.for_channel("development", "org.shelfarr.app.debug").map(&:version_code)
    assert_empty catalog.for_channel("release", "org.shelfarr.app.debug")
    assert_equal "2026.11.30-debug", catalog.for_channel("development", "org.shelfarr.app.debug").sole.version_name
  end

  test "skips entries this server cannot use and counts them" do
    good = catalog_entry(bytes: @bytes)
    invalid = [
      good.merge("channel" => "beta"),
      good.merge("package_name" => "org.shelfarr.app.debug"),
      good.merge("package_name" => "com.example.other"),
      good.except("consumer_api_versions"),
      good.merge("consumer_api_versions" => []),
      good.merge("consumer_api_versions" => [ "1" ]),
      good.merge("consumer_api_versions" => [ 1, 1 ]),
      good.merge("consumer_api_versions" => 1),
      good.merge("version_code" => "10"),
      good.merge("version_code" => 10.0),
      good.merge("version_code" => 0),
      good.merge("version_code" => 2_100_000_001),
      good.merge("version_name" => "0.1.2"),
      good.merge("version_name" => "2026.13.1"),
      good.merge("version_name" => "2026.11.1 beta"),
      good.merge("size_bytes" => 0),
      good.merge("size_bytes" => 256 * 1024 * 1024 + 1),
      good.merge("sha256" => "A" * 64),
      good.merge("sha256" => "a" * 63),
      good.merge("release_notes" => "x" * 4001),
      good.merge("release_notes" => 4),
      good.merge("min_sdk" => "26"),
      good.merge("apk_url" => "https://evil.example/app.apk"),
      good.merge("apk_url" => "http://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk"),
      good.merge("apk_url" => "not a url at all"),
      "not an object"
    ]
    catalog = parse([ good ] + invalid)

    assert_equal 1, catalog.releases.size
    assert_equal invalid.size, catalog.skipped
  end

  test "accepts newer API generations alongside the current one" do
    release = parse([ catalog_entry(bytes: @bytes, consumer_api_versions: [ 2, 1 ]) ]).releases.sole

    assert_equal [ 1, 2 ], release.consumer_api_versions
    assert release.compatible?
    assert_not release.compatible?([ 3 ])
  end

  test "refuses documents that are not a schema 1 catalog" do
    [
      "",
      "[]",
      "{not json",
      JSON.generate("schema_version" => 2, "releases" => []),
      JSON.generate("schema_version" => "1", "releases" => []),
      JSON.generate("schema_version" => 1),
      JSON.generate("schema_version" => 1, "releases" => {}),
      JSON.generate("schema_version" => 1, "releases" => Array.new(501) { {} }),
      "{\"schema_version\":1,\"releases\":[#{'[' * 20}#{']' * 20}]}",
      "\xFF\xFE".b
    ].each do |body|
      assert_raises(AndroidUpdates::Catalog::Invalid, body.inspect) { AndroidUpdates::Catalog.parse(body, policy: @policy) }
    end
  end

  test "refuses a catalog larger than the limit before parsing it" do
    body = catalog_json([ catalog_entry(bytes: @bytes, "release_notes" => "x" * 4000) ] * 300)

    assert_operator body.bytesize, :>, AndroidUpdates::Catalog::MAX_BYTES
    assert_raises(AndroidUpdates::Catalog::Invalid) { AndroidUpdates::Catalog.parse(body, policy: @policy) }
  end

  test "round-trips a release through its stored form" do
    release = parse([ catalog_entry(bytes: @bytes) ]).releases.sole

    assert_equal release, AndroidUpdates::Release.from_h(JSON.parse(JSON.generate(release.to_h)))
  end
end
