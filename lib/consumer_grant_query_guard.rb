# frozen_string_literal: true

require_relative "consumer_grant_log_filter"

# Rails query-parser exceptions can contain the original credential. Reject
# malformed sensitive queries before request/exception logging sees that error.
class ConsumerGrantQueryGuard
  TRANSFER_PATH = %r{(?:\A|/)api/consumer/v1/library/[^/]+/assets/[^/]+/transfer\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    query = env["QUERY_STRING"].to_s
    sensitive = query.split(/[&;]/).any? { |part| ConsumerGrantLogFilter.grant_key?(part.split("=", 2).first) }
    return @app.call(env) unless sensitive && malformed?(query)

    transfer = TRANSFER_PATH.match?(env["PATH_INFO"].to_s)
    body = transfer ? '{"error":"invalid_grant"}' : '{"error":"invalid_request"}'
    headers = { "content-type" => "application/json", "content-length" => body.bytesize.to_s,
      "cache-control" => "private, no-store", "referrer-policy" => "no-referrer" }
    [ transfer ? 401 : 400, headers, env["REQUEST_METHOD"] == "HEAD" ? [] : [ body ] ]
  end

  private

  def malformed?(query)
    ActionDispatch::ParamBuilder.from_query_string(query)
    false
  rescue ActionDispatch::ParamError, ArgumentError
    true
  end
end
