# frozen_string_literal: true

require "digest"

module AndroidUpdatesTestHelper
  CATALOG_URL = AndroidUpdates::Configuration::DEFAULT_CATALOG_URL
  RELEASE_DOWNLOADS = "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download"

  def setup_android_updates
    @android_root = Dir.mktmpdir("android-updates")
    AndroidUpdates::Store.root = @android_root
  end

  def teardown_android_updates
    AndroidUpdates::Store.root = nil
    FileUtils.chmod_R("u+w", @android_root) if @android_root && File.exist?(@android_root)
    FileUtils.remove_entry(@android_root) if @android_root && File.exist?(@android_root)
  end

  def android_store
    AndroidUpdates::Store.new(@android_root)
  end

  def fake_apk(seed)
    ("PK\x03\x04shelfarr-#{seed}-".b * 64).b
  end

  def catalog_entry(bytes:, channel: "release", version_code: 10, version_name: "2026.11.#{version_code}",
    apk_url: nil, consumer_api_versions: [ 1 ], **overrides)
    package = AndroidUpdates::Configuration::CHANNEL_PACKAGES.fetch(channel)
    {
      "channel" => channel,
      "package_name" => package,
      "version_code" => version_code,
      "version_name" => channel == "development" ? "#{version_name}-debug" : version_name,
      "apk_url" => apk_url || "#{RELEASE_DOWNLOADS}/android-#{channel}-#{version_code}/shelfarr-#{channel}-#{version_code}.apk",
      "size_bytes" => bytes.bytesize,
      "sha256" => Digest::SHA256.hexdigest(bytes),
      "min_sdk" => 26,
      "release_notes" => "Notes for #{version_code}",
      "consumer_api_versions" => consumer_api_versions
    }.merge(overrides.transform_keys(&:to_s))
  end

  def catalog_json(entries)
    JSON.generate("schema_version" => 1, "releases" => entries)
  end

  def stub_catalog(entries, url: CATALOG_URL)
    stub_request(:get, url).to_return(status: 200, body: catalog_json(entries), headers: { "Content-Type" => "application/json" })
  end

  def stub_apk(entry, bytes)
    stub_request(:get, entry.fetch("apk_url")).to_return(status: 200, body: bytes)
  end

  # Puts a verified build in the cache without the network.
  def promote_fixture(bytes, store: android_store, **entry_options)
    entry = catalog_entry(bytes: bytes, **entry_options)
    release = AndroidUpdates::Release.from_h(entry)
    staged = store.stage { |file| file.write(bytes) }
    store.promote!(release.channel, release, staged)
    release
  end

  # Fails if the block runs any SQL that changes data.
  def assert_no_database_writes(&block)
    writes = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      writes << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    assert_empty writes, "expected no database writes"
  end

  def android_tree
    Dir.glob(File.join(@android_root, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      stat = File.lstat(path)
      [ path, stat.size, stat.mtime.to_r, stat.mode ]
    end
  end
end
