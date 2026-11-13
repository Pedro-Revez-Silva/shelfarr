# frozen_string_literal: true

require "uri"

module AndroidUpdates
  # Which Android channels this server offers and where it gets them from.
  # Read from the server's environment only; nothing here is a user setting.
  #
  #   ANDROID_UPDATE_CATALOG_URL  publisher catalog (default: the official one)
  #   ANDROID_UPDATE_CHANNELS     comma list of release, development (default: release);
  #                               empty or "none" turns the feature off
  class Configuration
    CHANNEL_PACKAGES = {
      "release" => "org.shelfarr.app",
      "development" => "org.shelfarr.app.debug"
    }.freeze
    CHANNELS = CHANNEL_PACKAGES.keys.freeze
    DEFAULT_CHANNELS = %w[release].freeze
    DISABLED_VALUES = %w[none off false 0].freeze

    DEFAULT_CATALOG_URL =
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-catalog-v1/android-catalog.json"
    MAX_URL_LENGTH = 2048

    attr_reader :channels, :catalog_uri, :error

    def self.current
      new(ENV)
    end

    def initialize(env)
      channels, channel_error = parse_channels(env["ANDROID_UPDATE_CHANNELS"])
      uri, url_error = parse_catalog_url(env["ANDROID_UPDATE_CATALOG_URL"])
      @error = channel_error || url_error
      @channels = @error ? [] : channels
      @catalog_uri = uri
    end

    def enabled?(channel)
      channels.include?(channel)
    end

    def any_enabled?
      channels.any?
    end

    def misconfigured?
      error.present?
    end

    def default_source?
      catalog_uri.to_s == DEFAULT_CATALOG_URL
    end

    def package_for(channel)
      CHANNEL_PACKAGES.fetch(channel)
    end

    def source_policy
      SourcePolicy.new(catalog_uri, default_source: default_source?)
    end

    # The catalog's origin, which is safe to show or log; its path may not be.
    def source_label
      catalog_uri ? "#{catalog_uri.scheme}://#{catalog_uri.host}#{port_suffix}" : "not configured"
    end

    private

    def port_suffix
      catalog_uri.port == catalog_uri.default_port ? "" : ":#{catalog_uri.port}"
    end

    def parse_channels(raw)
      return [ DEFAULT_CHANNELS, nil ] if raw.nil?

      names = raw.split(",").map { |name| name.strip.downcase }.reject(&:empty?)
      return [ [], nil ] if names.empty? || (names.one? && DISABLED_VALUES.include?(names.first))

      unknown = names - CHANNELS
      return [ [], "ANDROID_UPDATE_CHANNELS may only list #{CHANNELS.join(' and ')}" ] if unknown.any?

      [ CHANNELS & names, nil ]
    end

    def parse_catalog_url(raw)
      value = raw.to_s.strip
      value = DEFAULT_CATALOG_URL if value.empty?
      invalid = [ nil, "ANDROID_UPDATE_CATALOG_URL must be an https URL without credentials, query or fragment" ]
      return invalid if value.length > MAX_URL_LENGTH

      uri = URI.parse(value)
      return invalid unless SourcePolicy.clean_https?(uri) && uri.path.end_with?(".json")

      uri.host = uri.host.downcase
      [ uri, nil ]
    rescue URI::InvalidURIError
      invalid
    end
  end
end
