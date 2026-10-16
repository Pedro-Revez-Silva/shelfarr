# frozen_string_literal: true

require "test_helper"

class ConnectionErrorClassifierTest < ActiveSupport::TestCase
  test "classifies Faraday timeouts" do
    result = ConnectionErrorClassifier.classify(Faraday::TimeoutError.new("execution expired"))

    assert_equal :timeout, result.reason
    assert_equal "Connection timed out", result.message
  end

  test "classifies open timeouts wrapped by Faraday" do
    error = Faraday::ConnectionFailed.new(Net::OpenTimeout.new("execution expired"))
    result = ConnectionErrorClassifier.classify(error)

    assert_equal :timeout, result.reason
    assert_equal "Connection timed out", result.message
  end

  test "classifies connection refused" do
    error = Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new("Connection refused - connect(2)"))
    result = ConnectionErrorClassifier.classify(error)

    assert_equal :connection_refused, result.reason
    assert_equal "Connection refused", result.message
  end

  test "classifies DNS failures from SocketError and getaddrinfo" do
    socket_error = Faraday::ConnectionFailed.new(
      SocketError.new("Failed to open TCP connection to prowlarr:9696 (getaddrinfo: Name or service not known)")
    )
    message_error = IndexerClients::Base::ConnectionError.new(
      "Failed to connect to Prowlarr: getaddrinfo: Name or service not known"
    )

    assert_equal :dns, ConnectionErrorClassifier.classify(socket_error).reason
    assert_equal "Could not resolve host", ConnectionErrorClassifier.classify(message_error).message
  end

  test "classifies TLS failures" do
    error = Faraday::SSLError.new("SSL certificate verify failed")
    result = ConnectionErrorClassifier.classify(error)

    assert_equal :tls, result.reason
    assert_equal "TLS connection failed", result.message
  end

  test "classifies unauthorized HTTP statuses and API key rejections" do
    status = ConnectionErrorClassifier.classify(status: 401)
    forbidden = ConnectionErrorClassifier.classify(status: 403)
    api_key = ConnectionErrorClassifier.classify(
      IndexerClients::Base::AuthenticationError.new("Invalid Prowlarr API key")
    )

    assert_equal :unauthorized, status.reason
    assert_equal "Unauthorized", status.message
    assert_equal :unauthorized, forbidden.reason
    assert_equal "Unauthorized", api_key.message
  end

  test "leaves unrelated failures unclassified" do
    error = IndexerClients::Base::Error.new("Prowlarr API error: 500")

    assert_nil ConnectionErrorClassifier.classify(error)
    assert_nil ConnectionErrorClassifier.classify(status: 404)
    assert_equal "Prowlarr API error: 500", ConnectionErrorClassifier.describe(error)
  end

  test "adds the container hint only for loopback connection failures" do
    hint = ConnectionErrorClassifier::LOCALHOST_HINT

    %w[http://localhost:9696 http://127.0.0.1:8080 http://[::1]:9696].each do |url|
      assert_equal "Connection refused. #{hint}", ConnectionErrorClassifier.with_localhost_hint("Connection refused", url)
    end

    assert_equal "Connection timed out", ConnectionErrorClassifier.with_localhost_hint("Connection timed out", "http://prowlarr:9696")
    assert_equal "Unauthorized", ConnectionErrorClassifier.with_localhost_hint("Unauthorized", "http://localhost:9696")
    assert_equal "Prowlarr API error: 500", ConnectionErrorClassifier.with_localhost_hint("Prowlarr API error: 500", "http://localhost:9696")
    assert_equal "Connection refused. #{hint}", ConnectionErrorClassifier.with_localhost_hint("Connection refused. #{hint}", "http://localhost:9696")
  end
end
