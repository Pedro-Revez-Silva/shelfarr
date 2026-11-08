# frozen_string_literal: true

require "uri"

module AndroidUpdates
  # One Android build, as listed by the publisher and as kept in the cache.
  # Every field is checked the same way the app checks its feed, so the server
  # never passes on something the phone would refuse.
  Release = Data.define(
    :channel, :package_name, :version_code, :version_name, :source_url,
    :size_bytes, :sha256, :min_sdk, :release_notes, :consumer_api_versions
  ) do
    def self.from_h(hash, policy: nil)
      ReleaseFields.new(hash, policy).build
    end

    def compatible?(api_versions = Consumer::ServerInfo::API_VERSIONS)
      consumer_api_versions.intersect?(api_versions)
    end

    def file_name
      "#{version_code}-#{sha256}.apk"
    end

    def same_build?(other)
      other && version_code == other.version_code && sha256 == other.sha256 &&
        size_bytes == other.size_bytes && version_name == other.version_name
    end

    def to_h
      {
        "channel" => channel,
        "package_name" => package_name,
        "version_code" => version_code,
        "version_name" => version_name,
        "apk_url" => source_url,
        "size_bytes" => size_bytes,
        "sha256" => sha256,
        "min_sdk" => min_sdk,
        "release_notes" => release_notes,
        "consumer_api_versions" => consumer_api_versions
      }.compact
    end
  end
end
