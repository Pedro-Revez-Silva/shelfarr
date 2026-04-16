# frozen_string_literal: true

require "cgi"

class UrlRedactor
  SENSITIVE_QUERY_KEYS = %w[
    apikey
    api_key
    token
    access_token
    refresh_token
    password
    pass
    passkey
    signature
    sig
    auth
    key
  ].freeze

  def self.redact(value)
    url = value.to_s
    return url if url.blank?

    base, fragment = url.split("#", 2)
    path, query = base.split("?", 2)
    return url if query.blank?

    redacted_query = query.split("&").map do |pair|
      key, = pair.split("=", 2)
      next pair if key.blank?

      sensitive_query_key?(key) ? "#{key}=[REDACTED]" : pair
    end.join("&")

    result = "#{path}?#{redacted_query}"
    fragment.present? ? "#{result}##{fragment}" : result
  end

  def self.sensitive_query_key?(key)
    SENSITIVE_QUERY_KEYS.include?(CGI.unescape(key.to_s).downcase)
  end

  private_class_method :sensitive_query_key?
end
