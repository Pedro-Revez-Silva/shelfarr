# frozen_string_literal: true

require "json"

module AndroidUpdates
  # The publisher's list of Android builds:
  #
  #   {"schema_version": 1, "releases": [<feed fields + consumer_api_versions>]}
  #
  # A malformed document is refused as a whole. Within a well-formed one, an
  # entry this server cannot use (an unknown future channel, a bad field) is
  # skipped and counted so a publisher can add entries for newer servers.
  class Catalog
    class Invalid < StandardError; end

    SCHEMA_VERSION = 1
    MAX_BYTES = 1024 * 1024
    MAX_RELEASES = 500

    attr_reader :releases, :skipped

    def self.parse(body, policy:)
      raise Invalid, "catalog is larger than #{MAX_BYTES} bytes" if body.bytesize > MAX_BYTES

      text = String.new(body, encoding: Encoding::UTF_8)
      raise Invalid, "catalog is not UTF-8" unless text.valid_encoding?

      document = JSON.parse(text, max_nesting: 8)
      raise Invalid, "catalog is not an object" unless document.is_a?(Hash)
      raise Invalid, "catalog schema_version is not #{SCHEMA_VERSION}" unless document["schema_version"] == SCHEMA_VERSION

      entries = document["releases"]
      raise Invalid, "catalog releases must be a list" unless entries.is_a?(Array)
      raise Invalid, "catalog lists more than #{MAX_RELEASES} releases" if entries.size > MAX_RELEASES

      new(entries, policy)
    rescue JSON::ParserError, JSON::NestingError
      raise Invalid, "catalog is not valid JSON"
    end

    def initialize(entries, policy)
      @skipped = 0
      @releases = entries.filter_map do |entry|
        Release.from_h(entry, policy: policy)
      rescue InvalidRelease
        @skipped += 1
        next
      end
    end

    def for_channel(channel, package_name)
      releases.select { |release| release.channel == channel && release.package_name == package_name }
    end
  end
end
