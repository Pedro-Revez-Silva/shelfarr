# frozen_string_literal: true

module OutboundNotifications
  class DiscordDelivery
    class ConfigurationError < StandardError; end
    class DeliveryError < StandardError; end

    EVENTS = WebhookDelivery::EVENTS
    TEST_EVENT = "test"
    USERNAME = "Shelfarr"

    MAX_CONTENT_LENGTH = 2_000
    MAX_EMBED_TITLE_LENGTH = 256
    MAX_EMBED_DESCRIPTION_LENGTH = 4_096
    MAX_FIELD_NAME_LENGTH = 256
    MAX_FIELD_VALUE_LENGTH = 1_024

    class << self
      def enabled?
        SettingsService.get(:discord_enabled, default: false)
      end

      def enabled_for?(event)
        enabled? && configured? && subscribed_events.include?(event)
      end

      def configured?
        discord_webhook_url.present?
      end

      def subscribed_events
        discord_events_string.split(",").map(&:strip).reject(&:blank?)
      end

      def deliver!(event:, title:, message:, request: nil)
        validate_configuration!
        validate_event!(event)

        response = connection.post(execute_url) do |req|
          req.headers = headers
          req.body = build_payload(
            event: event,
            title: title,
            message: message,
            request: request
          ).to_json
        end

        return response if response.success?

        raise DeliveryError, response_error_message(response)
      rescue URI::InvalidURIError => e
        raise DeliveryError, "Discord webhook URL is invalid: #{e.message}"
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise DeliveryError, "Discord webhook connection failed: #{e.message}"
      end

      def test_payload
        build_payload(
          event: TEST_EVENT,
          title: "Shelfarr Test",
          message: "Test notification from Shelfarr",
          request: nil
        )
      end

      private

      def validate_configuration!
        raise ConfigurationError, "Discord notifications are not enabled." unless enabled?
        raise ConfigurationError, "Discord webhook URL is not configured." if discord_webhook_url.blank?
      end

      def validate_event!(event)
        return if event == TEST_EVENT || EVENTS.include?(event)

        raise ConfigurationError, "Unsupported Discord notification event: #{event}"
      end

      def discord_webhook_url
        SettingsService.get(:discord_webhook_url).to_s.strip
      end

      def discord_events_string
        SettingsService.get(:discord_events).to_s
      end

      def connection
        Faraday.new do |f|
          f.options.timeout = 10
          f.options.open_timeout = 5
        end
      end

      def execute_url
        uri = URI.parse(discord_webhook_url)
        raise URI::InvalidURIError, "must use HTTP or HTTPS" unless uri.is_a?(URI::HTTP)

        query = Rack::Utils.parse_nested_query(uri.query)
        query["wait"] ||= "true"
        uri.query = query.to_query
        uri.to_s
      end

      def headers
        {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "Shelfarr/1.0"
        }
      end

      def build_payload(event:, title:, message:, request:)
        {
          content: truncate("#{title}: #{message}", MAX_CONTENT_LENGTH),
          username: USERNAME,
          allowed_mentions: { parse: [] },
          embeds: [ embed_for(event: event, title: title, message: message, request: request) ]
        }
      end

      def embed_for(event:, title:, message:, request:)
        embed = {
          title: truncate(title, MAX_EMBED_TITLE_LENGTH),
          description: truncate(message, MAX_EMBED_DESCRIPTION_LENGTH),
          color: color_for(event),
          timestamp: Time.current.iso8601,
          footer: { text: USERNAME },
          fields: fields_for(event: event, request: request)
        }

        embed.delete(:fields) if embed[:fields].empty?
        embed
      end

      def fields_for(event:, request:)
        fields = [ field("Event", event) ]
        return fields unless request.present?

        fields.concat([
          field("Book", request.book.title),
          field("Author", request.book.author),
          field("Type", request.book.book_type),
          field("Status", request.status),
          field("Requested By", request.user.username)
        ])
      end

      def field(name, value)
        {
          name: truncate(name.to_s, MAX_FIELD_NAME_LENGTH),
          value: truncate(value.to_s.presence || "Unknown", MAX_FIELD_VALUE_LENGTH),
          inline: true
        }
      end

      def color_for(event)
        case event
        when "request_created"
          0x3B82F6
        when "request_completed"
          0x22C55E
        when "request_failed"
          0xEF4444
        when "request_attention"
          0xF59E0B
        else
          0x6366F1
        end
      end

      def truncate(value, limit)
        value.to_s.truncate(limit)
      end

      def response_error_message(response)
        parsed = parse_json(response.body)
        if response.status == 429 && parsed["retry_after"].present?
          return "Discord webhook rate limited; retry after #{parsed['retry_after']} seconds"
        end

        detail = parsed["message"].presence || response.body.to_s.truncate(200)
        "Discord webhook returned HTTP #{response.status}: #{detail}"
      end

      def parse_json(body)
        JSON.parse(body.to_s.presence || "{}")
      rescue JSON::ParserError
        {}
      end
    end
  end
end
