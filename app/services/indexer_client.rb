# frozen_string_literal: true

class IndexerClient
  PROVIDERS = {
    "prowlarr" => IndexerClients::Prowlarr,
    "jackett" => IndexerClients::Jackett
  }.freeze

  class << self
    def provider
      SettingsService.active_indexer_provider
    end

    def current
      PROVIDERS[provider]
    end

    def configured?
      current&.configured? || false
    end

    def search(...)
      current&.search(...)
    end

    def test_connection
      current&.test_connection || false
    end

    def reset_connection!
      current&.reset_connection!
    end

    def reset_all_connections!
      PROVIDERS.values.each(&:reset_connection!)
    end

    def display_name
      current&.display_name || "Indexer"
    end
  end
end
