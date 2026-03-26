# frozen_string_literal: true

module OutboundNotifications
  class WebhookDelivery
    class ConfigurationError < StandardError; end
    class DeliveryError < StandardError; end

    EVENTS = %w[request_created request_completed request_failed request_attention].freeze
    TEST_EVENT = "test"

    class << self
      def enabled?
        SettingsService.get(:webhook_enabled, default: false)
      end

      def enabled_for?(event)
        enabled? && configured? && subscribed_events.include?(event)
      end

      def configured?
        webhook_url.present?
      end

      def subscribed_events
        webhook_events_string.split(",").map(&:strip).reject(&:blank?)
      end

      def deliver!(event:, title:, message:, request: nil)
        validate_configuration!
        validate_event!(event)

        response = connection.post(webhook_url) do |req|
          req.headers = headers_for(event)
          req.body = build_payload(
            event: event,
            title: title,
            message: message,
            request: request
          ).to_json
        end

        return response if response.success?

        raise DeliveryError, "Webhook returned HTTP #{response.status}: #{response.body.to_s.truncate(200)}"
      rescue URI::InvalidURIError => e
        raise DeliveryError, "Webhook URL is invalid: #{e.message}"
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise DeliveryError, "Webhook connection failed: #{e.message}"
      end

      def test_payload
        {
          event: TEST_EVENT,
          title: "Shelfarr Test",
          message: "Test notification from Shelfarr"
        }
      end

      private

      def validate_configuration!
        raise ConfigurationError, "Webhooks are not enabled." unless enabled?
        raise ConfigurationError, "Webhook URL is not configured." if webhook_url.blank?
      end

      def validate_event!(event)
        return if event == TEST_EVENT || EVENTS.include?(event)

        raise ConfigurationError, "Unsupported webhook event: #{event}"
      end

      def webhook_url
        SettingsService.get(:webhook_url).to_s.strip
      end

      def webhook_events_string
        SettingsService.get(:webhook_events).to_s
      end

      def connection
        Faraday.new do |f|
          f.options.timeout = 10
          f.options.open_timeout = 5
        end
      end

      def headers_for(event)
        headers = {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "Shelfarr/1.0",
          "X-Shelfarr-Event" => event
        }

        token = SettingsService.get(:webhook_token).to_s.strip
        if token.present?
          headers["Authorization"] = token.start_with?("Bearer ") ? token : "Bearer #{token}"
        end

        headers
      end

      def build_payload(event:, title:, message:, request:)
        payload = {
          event: event,
          title: title,
          message: message,
          occurred_at: Time.current.iso8601
        }

        return payload unless request.present?

        payload.merge(
          request: {
            id: request.id,
            status: request.status,
            attention_needed: request.attention_needed
          },
          book: {
            id: request.book_id,
            title: request.book.title,
            author: request.book.author,
            book_type: request.book.book_type
          },
          user: {
            id: request.user_id,
            username: request.user.username
          }
        )
      end
    end
  end
end
