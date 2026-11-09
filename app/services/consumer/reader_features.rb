# frozen_string_literal: true

# Optional reader features a consumer client understands, from the additive
# v1 capability header `X-Shelfarr-Reader-Features: read-along`.
#
# Features are not formats: they add fields that installed clients have never
# seen, so they appear only when declared. A missing header keeps every
# existing projection unchanged. Unknown names are ignored, so a newer client
# still works with a server that doesn't offer one of its features; malformed
# values are refused.
module Consumer::ReaderFeatures
  class Invalid < StandardError; end

  HEADER = "X-Shelfarr-Reader-Features"
  SUPPORTED = %w[read-along].freeze
  MAX_BYTES = 128
  NAME = /\A[a-z][a-z0-9-]{0,31}\z/

  Selection = Data.define(:features) do
    def read_along? = features.include?("read-along")
  end

  NONE = Selection.new(features: [].freeze)
  WEB = Selection.new(features: SUPPORTED)

  module_function

  def from(request)
    parse(request.headers[HEADER])
  end

  def parse(value)
    return NONE if value.nil?
    raise Invalid, "Declare reader features as a comma-separated list such as read-along" unless value.is_a?(String) && value.bytesize.between?(1, MAX_BYTES)

    names = value.split(",", -1).map(&:strip)
    raise Invalid, "Reader feature names are lowercase words joined by hyphens" unless names.all? { |name| name.match?(NAME) }

    Selection.new(features: (names & SUPPORTED).sort.freeze)
  end
end
