# frozen_string_literal: true

require "yaml"

module Shelfarr
  class ReleaseChannel
    class Invalid < StandardError; end

    SOURCE = "config/release_channel.yml"
    NAMES = %w[stable beta].freeze
    SERIES_FORMAT = /\A[1-9]\d{0,2}\.\d{1,3}\z/
    CALENDAR_VERSION = /\A(?<date>20\d{2}\.\d{2}\.\d{2})\.(?<number>[1-9]\d{0,5})\z/
    BETA_SUFFIX = "-beta"

    attr_reader :name, :series

    def self.load(root)
      path = File.join(root.to_s, SOURCE)
      raise Invalid, "#{SOURCE} is missing" unless File.file?(path)

      document = YAML.safe_load(File.read(path, 4096))
      raise Invalid, "#{SOURCE} must be a mapping" unless document.is_a?(Hash)
      raise Invalid, "#{SOURCE} has unknown keys" unless document.keys.sort == %w[channel series]

      new(name: document["channel"], series: document["series"])
    rescue Psych::Exception => error
      raise Invalid, "#{SOURCE} is not valid YAML: #{error.message}"
    end

    def self.current
      @current ||= load(Rails.root)
    end

    def initialize(name:, series:)
      raise Invalid, "Release channel must be one of #{NAMES.join(', ')}, not #{name.inspect}" unless NAMES.include?(name)
      raise Invalid, "Release series must look like 1.0, not #{series.inspect}" unless series.is_a?(String) && series.match?(SERIES_FORMAT)

      @name = name
      @series = series
      freeze
    end

    def beta?
      name == "beta"
    end

    def stable?
      name == "stable"
    end

    def label
      beta? ? "Shelfarr #{series} Beta" : "Shelfarr #{series}"
    end

    def image_channel_tag
      beta? ? "beta" : "latest"
    end

    def version_for(calendar_version)
      raise Invalid, "#{calendar_version.inspect} is not a calendar build number" unless calendar_version.match?(CALENDAR_VERSION)

      beta? ? "#{calendar_version}#{BETA_SUFFIX}" : calendar_version
    end

    def self.published_version?(version)
      calendar = version.to_s.delete_suffix(BETA_SUFFIX)
      calendar.match?(CALENDAR_VERSION)
    end

    def self.beta_version?(version)
      published_version?(version) && version.end_with?(BETA_SUFFIX)
    end
  end
end
