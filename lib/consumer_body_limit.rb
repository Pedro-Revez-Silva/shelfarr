# frozen_string_literal: true

require "stringio"

class ConsumerBodyLimit
  MAX_BYTES = 64 * 1024

  def initialize(app)
    @app = app
  end

  def call(env)
    if env["PATH_INFO"].to_s.match?(%r{(?:\A|/)api/consumer/}) && %w[POST PUT PATCH].include?(env["REQUEST_METHOD"])
      data = env["rack.input"]&.read(MAX_BYTES + 1).to_s
      return [ 413, { "content-type" => "application/json", "cache-control" => "no-store" }, [ '{"error":"request_too_large"}' ] ] if data.bytesize > MAX_BYTES

      env["rack.input"] = StringIO.new(data)
    end
    @app.call(env)
  end
end
