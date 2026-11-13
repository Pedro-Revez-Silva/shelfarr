# frozen_string_literal: true

require "uri"

# filter_parameters compares the raw query key in Rails' "Started GET" line,
# so `gr%61nt=`, `grant[]=` or `x[grant]=` would log the value even though
# Rack decodes them to a grant parameter. Redact any key that decodes to a
# `grant` name, on every route, including unknown ones.
module ConsumerGrantLogFilter
  private

  def filtered_query_string
    super.split(/([&;])/).map { |part| ConsumerGrantLogFilter.redact(part) }.join
  end

  def self.redact(part)
    key, value = part.split("=", 2)
    return part if value.nil?

    grant_key?(key) ? "#{key}=[FILTERED]" : part
  end

  def self.grant_key?(key)
    key = key.to_s
    decoded = begin
      URI.decode_www_form_component(key)
    rescue ArgumentError
      key
    end
    decoded = decoded.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    decoded.scan(/[^\[\]]+/).any? { |name| name.strip.casecmp?("grant") }
  end
end
