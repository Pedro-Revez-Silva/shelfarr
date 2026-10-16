# frozen_string_literal: true

class ConnectionProbe
  class << self
    def indexer(provider:, url:, api_key:)
      client = IndexerClient::PROVIDERS[provider.to_s]
      raise IndexerClients::Base::NotConfiguredError, "Indexer is not configured" if client.nil?

      client.test_connection(url: url, api_key: api_key)
    rescue IndexerClients::Base::Error => e
      raise e.class, ConnectionErrorClassifier.with_localhost_hint(e.message, url)
    end

    def audiobookshelf(url:, api_key:)
      AudiobookshelfClient.test_connection(url: url, api_key: api_key)
    rescue AudiobookshelfClient::Error => e
      raise e.class, ConnectionErrorClassifier.with_localhost_hint(e.message, url)
    end

    def qbittorrent(url:, username: nil, password: nil, api_key: nil, category: nil)
      client = DownloadClient.new(
        name: "Connection probe",
        client_type: "qbittorrent",
        url: url,
        username: username,
        password: password,
        api_key: api_key,
        category: category,
        priority: 0,
        enabled: false
      )
      client.validate
      if (url_error = client.errors[:url].first)
        raise DownloadClients::Base::ConnectionError, "qBittorrent URL #{url_error}"
      end

      client.test_connection
    rescue DownloadClients::Base::Error => e
      raise e.class, ConnectionErrorClassifier.with_localhost_hint(e.message, client&.url || url)
    end
  end
end
