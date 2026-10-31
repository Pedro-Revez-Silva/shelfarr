# frozen_string_literal: true

class IndexerClient
  PROVIDERS = {
    "prowlarr" => IndexerClients::Prowlarr,
    "jackett" => IndexerClients::Jackett,
    "newznab" => IndexerClients::Newznab
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
      result = current&.test_connection
      return false if result.nil?
      return result if RemoteResult.failed?(result)

      result || false
    end

    def reset_connection!
      current&.reset_connection!
    end

    def reset_all_connections!
      PROVIDERS.values.each(&:reset_connection!)
    end

    def release_unconfigured_connections!
      PROVIDERS.each_value(&:release_unconfigured_connection!)
    end

    def display_name
      current&.display_name || "Indexer"
    end
  end
end
