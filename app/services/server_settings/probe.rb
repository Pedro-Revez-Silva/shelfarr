# frozen_string_literal: true

module ServerSettings
  class Probe
    Outcome = Data.define(:tone, :message) do
      def self.notice(message) = new(tone: :notice, message: message)
      def self.alert(message) = new(tone: :alert, message: message)

      def success?
        tone == :notice
      end
    end

    WebhookModeNotSaved = Class.new(StandardError)

    NAMES = %w[
      indexer audiobookshelf flaresolverr hardcover google_books open_library comic_vine zlibrary
      librivox gutenberg ebooks_com oidc webhook discord telegram telegram_webhook
    ].freeze

    INDEXER_PROVIDERS = %w[none prowlarr jackett newznab].freeze
    INDEXER_PROBE_KEYS = {
      "prowlarr" => [ :prowlarr_url, :prowlarr_api_key ],
      "jackett" => [ :jackett_url, :jackett_api_key ],
      "newznab" => [ :newznab_url, :newznab_api_key ]
    }.freeze
    POSTED_KEYS = %w[indexer_provider prowlarr_url prowlarr_api_key jackett_url jackett_api_key newznab_url newznab_api_key
      library_platform audiobookshelf_url audiobookshelf_api_key].freeze

    def initialize(posted: {}, telegram_webhook_url: nil)
      @posted = submitted_values(posted).transform_keys(&:to_s).slice(*POSTED_KEYS)
      @telegram_webhook_url = telegram_webhook_url
    end

    def call(name)
      raise ArgumentError, "Unknown connection check: #{name}" unless NAMES.include?(name.to_s)

      public_send(name)
    end

    def indexer
      provider = indexer_provider
      name = IndexerClient::PROVIDERS[provider]&.display_name || "Indexer"
      url, api_key = indexer_credentials(provider)
      health = health_for("indexer", saved: saved_indexer?(provider, url, api_key))

      unless url.present? && api_key.present?
        health&.mark_not_configured!
        return Outcome.alert("#{name} is not configured. Select a provider and enter connection details first.")
      end

      if RemoteResult.succeeded?(ConnectionProbe.indexer(provider: provider, url: url, api_key: api_key))
        health&.check_succeeded!(message: "Connection successful")
        Outcome.notice("#{name} connection successful!")
      else
        health&.check_failed!(message: "Failed to connect to #{name}")
        Outcome.alert("#{name} connection failed.")
      end
    rescue IndexerClients::Base::Error => e
      health&.check_failed!(message: e.message)
      Outcome.alert("#{name} error: #{e.message}")
    end

    def audiobookshelf
      platform = library_platform
      name = LibraryPlatformClient.display_name(platform)
      url, api_key = library_credentials(platform)
      health = health_for("audiobookshelf", saved: saved_library?(platform, url, api_key))

      unless library_configured?(platform, url, api_key)
        health&.mark_not_configured!
        return Outcome.alert("#{name} is not configured. Enter connection details first.")
      end

      connected = if platform == "audiobookshelf"
        ConnectionProbe.audiobookshelf(url: url, api_key: api_key)
      else
        LibraryPlatformClient.test_connection(platform: platform)
      end

      if RemoteResult.succeeded?(connected)
        health&.check_succeeded!(message: "Connection successful")
        Outcome.notice("#{name} connection successful!")
      else
        health&.check_failed!(message: "Failed to connect to #{name}")
        Outcome.alert("#{name} connection failed.")
      end
    rescue LibraryPlatformClient::Error, AudiobookshelfClient::Error => e
      health&.check_failed!(message: e.message)
      Outcome.alert("#{name} error: #{e.message}")
    end

    def flaresolverr
      return Outcome.alert("FlareSolverr URL is not configured.") unless FlaresolverrClient.configured?

      if RemoteResult.succeeded?(FlaresolverrClient.test_connection)
        Outcome.notice("FlareSolverr connection successful!")
      else
        Outcome.alert("FlareSolverr connection failed.")
      end
    rescue FlaresolverrClient::Error => e
      Outcome.alert("FlareSolverr error: #{e.message}")
    end

    def hardcover
      health = SystemHealth.for_service("hardcover")

      unless HardcoverClient.configured?
        health.mark_not_configured!
        return Outcome.alert("Hardcover is not configured. Enter API token first.")
      end

      if RemoteResult.succeeded?(HardcoverClient.test_connection)
        MetadataProviderStatus.for_provider("hardcover").record_success!
        health.check_succeeded!(message: "Connection successful")
        Outcome.notice("Hardcover connection successful!")
      else
        health.check_failed!(message: "Failed to connect to Hardcover")
        Outcome.alert("Hardcover connection failed.")
      end
    rescue HardcoverClient::RateLimitError => e
      MetadataProviderStatus.for_provider("hardcover").record_failure!(e)
      health&.check_failed!(message: e.message, degraded: true)
      Outcome.alert("Hardcover is rate limited. #{e.message}")
    rescue HardcoverClient::Error => e
      health&.check_failed!(message: e.message)
      Outcome.alert("Hardcover error: #{e.message}")
    end

    def google_books
      metadata_probe("google_books", "Google Books", GoogleBooksClient, "Google Books is not enabled.")
    end

    def open_library
      metadata_probe("openlibrary", "Open Library", OpenLibraryClient, "Open Library is not enabled.")
    end

    def comic_vine
      metadata_probe("comic_vine", "Comic Vine", ComicVineClient, "Comic Vine is not configured. Enable it and enter an API key first.")
    end

    def zlibrary
      return Outcome.alert("Z-Library is not configured. Enable it and enter your account credentials first.") unless ZLibraryClient.configured?

      ZLibraryClient.test_connection! ? Outcome.notice("Z-Library connection successful!") : Outcome.alert("Z-Library connection failed.")
    rescue ZLibraryClient::Error => e
      Outcome.alert("Z-Library error: #{e.message}")
    end

    def librivox
      catalogue_probe(LibrivoxClient, "LibriVox", "LibriVox is not enabled.")
    end

    def gutenberg
      catalogue_probe(GutenbergClient, "Project Gutenberg", "Project Gutenberg is not enabled.")
    end

    def ebooks_com
      return Outcome.alert("Enable eBooks.com and enter a valid two-letter buyer country code first.") unless EbooksComClient.configured?

      if RemoteResult.succeeded?(EbooksComClient.test_connection)
        Outcome.notice("eBooks.com catalog connection successful!")
      else
        Outcome.alert("eBooks.com catalog connection failed.")
      end
    end

    def oidc
      return Outcome.alert("OIDC is not enabled. Enable it first.") unless SettingsService.get(:oidc_enabled, default: false)

      issuer = SettingsService.get(:oidc_issuer).to_s.strip
      return Outcome.alert("OIDC issuer URL is not configured.") if issuer.blank?

      response = Faraday.get("#{issuer.chomp('/')}/.well-known/openid-configuration")
      return Outcome.alert("Failed to fetch OIDC discovery document (HTTP #{response.status}).") unless response.status == 200

      config = JSON.parse(response.body)
      if config["issuer"].present? && config["authorization_endpoint"].present?
        Outcome.notice("OIDC configuration valid! Provider: #{config['issuer']}")
      else
        Outcome.alert("OIDC discovery document is incomplete.")
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      Outcome.alert("Could not connect to OIDC provider: #{e.message}")
    rescue JSON::ParserError
      Outcome.alert("Invalid OIDC discovery document (not valid JSON).")
    rescue StandardError => e
      Outcome.alert("OIDC test error: #{e.message}")
    end

    def webhook
      payload = OutboundNotifications::WebhookDelivery.test_payload
      OutboundNotifications::WebhookDelivery.deliver!(event: payload[:event], title: payload[:title], message: payload[:message])
      Outcome.notice("Webhook test sent successfully!")
    rescue OutboundNotifications::WebhookDelivery::ConfigurationError, OutboundNotifications::WebhookDelivery::DeliveryError => e
      Outcome.alert(e.message)
    end

    def discord
      OutboundNotifications::DiscordDelivery.deliver!(
        event: OutboundNotifications::DiscordDelivery::TEST_EVENT,
        title: "Shelfarr Test",
        message: "Test notification from Shelfarr"
      )
      Outcome.notice("Discord test sent successfully!")
    rescue OutboundNotifications::DiscordDelivery::ConfigurationError, OutboundNotifications::DiscordDelivery::DeliveryError => e
      Outcome.alert(e.message)
    end

    def telegram
      unless Integrations::Telegram::Configuration.configured?
        return Outcome.alert("Telegram is not fully configured. Enable it and enter bot token and webhook secret first.")
      end

      username = Integrations::Telegram::Client.get_me.dig("result", "username") || "bot"
      Outcome.notice("Telegram connection successful: @#{username}")
    rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError => e
      Outcome.alert(e.message)
    end

    def telegram_webhook
      unless SettingsService.get(:telegram_enabled, default: false) && Integrations::Telegram::Configuration.bot_token.present? && Integrations::Telegram::Configuration.webhook_secret.present?
        return Outcome.alert("Telegram is not fully configured. Enable it and enter bot token and webhook secret first.")
      end

      Integrations::Telegram::Client.set_webhook!(url: telegram_webhook_url)
      save_webhook_mode!
      TelegramPollingJob.clear_schedule!
      Outcome.notice("Telegram webhook configured: #{telegram_webhook_url}")
    rescue WebhookModeNotSaved
      polling_kept
    rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError => e
      Outcome.alert(e.message)
    end

    private

    attr_reader :posted, :telegram_webhook_url

    def submitted_values(posted)
      return posted.to_unsafe_h if posted.respond_to?(:to_unsafe_h)

      posted.is_a?(Hash) ? posted : {}
    end

    def save_webhook_mode!
      SettingsService.set(:telegram_update_mode, "webhook")
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[SettingsController] Telegram accepted the webhook but the delivery mode could not be saved: #{e.class}")
      raise WebhookModeNotSaved
    end

    def polling_kept
      Integrations::Telegram::Client.delete_webhook!(drop_pending_updates: false)
      Outcome.alert("Telegram accepted the webhook, but Shelfarr could not save the change, so it kept polling. Try again in a moment.")
    rescue Integrations::Telegram::Client::ConfigurationError, Integrations::Telegram::Client::DeliveryError
      Outcome.alert("Telegram accepted the webhook, but Shelfarr could not save the change or undo the registration. Try again in a moment; until then the bot may not receive messages.")
    end

    def metadata_probe(provider, name, client, not_configured)
      return Outcome.alert(not_configured) unless client.configured?

      if RemoteResult.succeeded?(client.test_connection)
        MetadataProviderStatus.for_provider(provider).record_success!
        Outcome.notice("#{name} connection successful!")
      else
        Outcome.alert("#{name} connection failed.")
      end
    rescue client::Error => e
      Outcome.alert("#{name} error: #{e.message}")
    end

    def catalogue_probe(client, name, not_configured)
      return Outcome.alert(not_configured) unless client.configured?

      RemoteResult.succeeded?(client.test_connection) ? Outcome.notice("#{name} connection successful!") : Outcome.alert("#{name} connection failed.")
    end

    def indexer_provider
      if posted.key?("indexer_provider")
        value = posted["indexer_provider"].to_s.strip
        return value if INDEXER_PROVIDERS.include?(value)
      end

      SettingsService.active_indexer_provider
    end

    def indexer_credentials(provider)
      url_key, secret_key = INDEXER_PROBE_KEYS[provider]
      return [ "", "" ] unless url_key

      [ posted_or_saved(url_key).to_s.strip, posted_or_saved_secret(secret_key).to_s ]
    end

    def library_platform
      if posted.key?("library_platform")
        value = posted["library_platform"].to_s.strip
        return value if value.present?
      end

      LibraryPlatformClient.active_platform
    end

    def library_credentials(platform)
      return [ nil, nil ] unless platform == "audiobookshelf"

      [ posted_or_saved(:audiobookshelf_url).to_s.strip, posted_or_saved_secret(:audiobookshelf_api_key).to_s ]
    end

    def library_configured?(platform, url, api_key)
      return url.present? && api_key.present? if platform == "audiobookshelf"

      LibraryPlatformClient.configured?(platform: platform)
    end

    def health_for(service, saved:)
      SystemHealth.for_service(service) if saved
    end

    def saved_indexer?(provider, url, api_key)
      url_key, secret_key = INDEXER_PROBE_KEYS[provider]
      return provider == SettingsService.active_indexer_provider if url_key.nil?

      provider == SettingsService.active_indexer_provider &&
        url == SettingsService.get(url_key).to_s.strip &&
        api_key == SettingsService.get(secret_key).to_s
    end

    def saved_library?(platform, url, api_key)
      return false unless platform == LibraryPlatformClient.active_platform
      return true unless platform == "audiobookshelf"

      url == SettingsService.get(:audiobookshelf_url).to_s.strip &&
        api_key == SettingsService.get(:audiobookshelf_api_key).to_s
    end

    def posted_or_saved(key)
      posted.key?(key.to_s) ? posted[key.to_s] : SettingsService.get(key)
    end

    def posted_or_saved_secret(key)
      value = posted_or_saved(key)
      value.blank? ? SettingsService.get(key) : value
    end
  end
end
