# frozen_string_literal: true

class ConnectionErrorClassifier
  MESSAGES = {
    timeout: "Connection timed out",
    connection_refused: "Connection refused",
    dns: "Could not resolve host",
    tls: "TLS connection failed",
    unauthorized: "Unauthorized"
  }.freeze
  LOCALHOST_HINT = "That address is this container, not Prowlarr or qBittorrent. Use the Docker service name or a LAN IP."
  CONNECTION_FAILURE_MESSAGES = MESSAGES.except(:unauthorized).values.freeze
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  Classification = Data.define(:reason, :message)

  class << self
    def classify(error = nil, status: nil)
      reason = reason_for_status(status) || reason_for(error)
      return if reason.nil?

      Classification.new(reason: reason, message: MESSAGES.fetch(reason))
    end

    def describe(error)
      classify(error)&.message || error.message.to_s
    end

    def with_localhost_hint(message, url)
      text = message.to_s
      return text if text.include?(LOCALHOST_HINT)
      return text unless loopback_url?(url)
      return text unless CONNECTION_FAILURE_MESSAGES.any? { |known| text.include?(known) }

      "#{text} #{LOCALHOST_HINT}"
    end

    def reraise!(error, connection_error:, authentication_error:)
      classification = classify(error)
      if classification.nil?
        raise error
      elsif classification.reason == :unauthorized
        raise authentication_error, classification.message
      else
        raise connection_error, classification.message
      end
    end

    private

    def loopback_url?(url)
      host = URI.parse(url.to_s).host.to_s.downcase.delete_prefix("[").delete_suffix("]")
      LOOPBACK_HOSTS.include?(host)
    rescue URI::InvalidURIError
      false
    end

    def reason_for_status(status)
      return if status.blank?

      :unauthorized if [ 401, 403 ].include?(status.to_i)
    end

    def reason_for(error)
      return if error.nil?

      each_exception(error) do |candidate|
        reason = reason_for_class(candidate)
        return reason if reason
      end

      reason_for_message(error.message)
    end

    def each_exception(error)
      current = error
      seen = {}

      while current && !seen[current.object_id] && seen.size < 5
        seen[current.object_id] = true
        yield current
        current = wrapped_exception(current) || current.cause
      end
    end

    def wrapped_exception(error)
      return unless error.respond_to?(:wrapped_exception)

      error.wrapped_exception
    end

    def reason_for_class(error)
      case error
      when Faraday::SSLError, OpenSSL::SSL::SSLError
        :tls
      when Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        :timeout
      when Errno::ECONNREFUSED
        :connection_refused
      when SocketError
        :dns
      end
    end

    def reason_for_message(message)
      text = message.to_s
      return :tls if text.match?(/SSL|certificate verify failed|\bTLS\b/)
      return :dns if text.match?(/getaddrinfo|Name or service not known|nodename nor servname|no address associated with hostname/i)
      return :connection_refused if text.match?(/ECONNREFUSED|Connection refused/)
      return :timeout if text.match?(/timed out|execution expired|\btimeout\b/i)
      return :unauthorized if text.match?(/\b401\b|\b403\b|invalid .+ api key/i)

      nil
    end
  end
end
