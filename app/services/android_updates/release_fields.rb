# frozen_string_literal: true

require "uri"

module AndroidUpdates
  # Validation for Release.from_h, kept apart so Release stays a value.
  class ReleaseFields
    MAX_VERSION_CODE = 2_100_000_000
    MAX_APK_BYTES = 256 * 1024 * 1024
    MAX_NOTES_CHARS = 4_000
    MAX_API_VERSIONS = 16
    VERSION_NAME = /\A[0-9A-Za-z][0-9A-Za-z._+-]{0,63}\z/
    # Calendar versions: YEAR.MONTH.NUMBER with an optional suffix such as -debug.
    CALVER = /\A(?<year>20\d{2})\.(?<month>0?[1-9]|1[0-2])\.\d{1,6}(?:[.+-][0-9A-Za-z._+-]*)?\z/
    SHA256 = /\A[0-9a-f]{64}\z/

    def initialize(hash, policy)
      raise InvalidRelease, "release is not an object" unless hash.is_a?(Hash)

      @hash = hash
      @policy = policy
    end

    def build
      channel = string("channel", 64)
      package = string("package_name", 255)
      unless Configuration::CHANNEL_PACKAGES[channel] == package
        raise InvalidRelease, "unknown channel or package"
      end

      name = string("version_name", 64)
      raise InvalidRelease, "version_name is not a calendar version" unless name.match?(VERSION_NAME) && name.match?(CALVER)

      digest = string("sha256", 64)
      raise InvalidRelease, "sha256 is not lowercase SHA-256" unless digest.match?(SHA256)

      Release.new(
        channel: channel, package_name: package,
        version_code: integer("version_code", 1..MAX_VERSION_CODE),
        version_name: name, source_url: source_url,
        size_bytes: integer("size_bytes", 1..MAX_APK_BYTES), sha256: digest,
        min_sdk: optional_integer("min_sdk", 1..1000), release_notes: notes,
        consumer_api_versions: api_versions
      )
    end

    private

    def string(key, max)
      value = @hash[key]
      unless value.is_a?(String) && !value.empty? && value.length <= max && value.valid_encoding?
        raise InvalidRelease, "#{key} is missing or not a short string"
      end

      value
    end

    def integer(key, range)
      value = @hash[key]
      raise InvalidRelease, "#{key} must be a whole number in range" unless value.is_a?(Integer) && range.cover?(value)

      value
    end

    def optional_integer(key, range)
      @hash[key].nil? ? nil : integer(key, range)
    end

    def notes
      value = @hash["release_notes"]
      return nil if value.nil?
      unless value.is_a?(String) && value.length <= MAX_NOTES_CHARS && value.valid_encoding?
        raise InvalidRelease, "release_notes must be plain text of at most #{MAX_NOTES_CHARS} characters"
      end

      value.presence
    end

    def api_versions
      value = @hash["consumer_api_versions"]
      valid = value.is_a?(Array) && value.size.between?(1, MAX_API_VERSIONS) &&
        value.all? { |version| version.is_a?(Integer) && version.between?(1, 1000) } && value.uniq.size == value.size
      raise InvalidRelease, "consumer_api_versions must list API generations" unless valid

      value.sort.freeze
    end

    def source_url
      raw = string("apk_url", 2048)
      uri = URI.parse(raw)
      allowed = @policy ? @policy.allowed_artifact?(uri) : SourcePolicy.clean_https?(uri)
      raise InvalidRelease, "apk_url is not at a trusted location" unless allowed

      raw
    rescue URI::InvalidURIError
      raise InvalidRelease, "apk_url is not a URL"
    end
  end
end
