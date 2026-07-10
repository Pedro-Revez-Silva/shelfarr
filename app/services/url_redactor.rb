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
    x-amz-signature
    x-amz-credential
    x-amz-security-token
    x-goog-signature
    x-goog-credential
    x-goog-security-token
    policy
    key-pair-id
    awsaccesskeyid
    googleaccessid
  ].freeze

  def self.redact(value)
    url = value.to_s
    return url if url.blank?

    base, fragment = url.split("#", 2)
    path, query = base.split("?", 2)
    path = redact_userinfo(path)
    return append_redacted_fragment(path, fragment) if query.blank?

    redacted_query = query.split("&").map do |pair|
      key, = pair.split("=", 2)
      next pair if key.blank?

      sensitive_query_key?(key) ? "#{key}=[REDACTED]" : pair
    end.join("&")

    append_redacted_fragment("#{path}?#{redacted_query}", fragment)
  end

  def self.sensitive_query_key?(key)
    SENSITIVE_QUERY_KEYS.include?(CGI.unescape(key.to_s).downcase)
  end

  def self.redact_userinfo(path)
    path.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, '\1[REDACTED]@')
  end

  def self.append_redacted_fragment(value, fragment)
    fragment.nil? ? value : "#{value}#[REDACTED]"
  end

  private_class_method :sensitive_query_key?, :redact_userinfo, :append_redacted_fragment
end
