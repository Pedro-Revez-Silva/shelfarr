# frozen_string_literal: true

module WebPreview
  class DownloadManagement
    TYPE_LABELS = {
      "qbittorrent" => "qBittorrent",
      "decypharr" => "Decypharr",
      "sabnzbd" => "SABnzbd",
      "nzbget" => "NZBGet",
      "deluge" => "Deluge",
      "transmission" => "Transmission"
    }.freeze
    API_KEY_TYPES = %w[sabnzbd qbittorrent].freeze
    VERIFICATION_TYPES = %w[qbittorrent].freeze
    HEALTH_SERVICE = "download_client"
    HEALTH_SENTENCES = {
      "healthy" => "Every enabled client answered the last check.",
      "degraded" => "Some enabled clients did not answer the last check. Test each client to see which.",
      "down" => "No enabled client answered the last check. Test each client to see why.",
      "not_configured" => "There is no enabled download client.",
      "unknown" => "The last check did not finish."
    }.freeze

    def self.health_sentence(status)
      HEALTH_SENTENCES[status.to_s]
    end

    def self.version(record)
      record.updated_at.utc.iso8601(6)
    end

    def representation
      clients = DownloadClientAdministration.ordered.to_a
      rule_ids = DownloadRoutingRule.pluck(:download_client_id, :id).group_by(&:first).transform_values { |pairs| pairs.map { |_, id| id.to_s }.sort }
      {
        clients: clients.map { |client| client_json(client, rule_ids.fetch(client.id, [])) },
        rules: DownloadRoutingRule.eager_load(:download_client).where.not(download_clients: { id: nil }).by_indexer.map { |rule| rule_json(rule) },
        client_types: DownloadClient.client_types.keys.map { |type| type_json(type) },
        providers: DownloadRoutingRule::PROVIDERS.map { |value, label| { value: value, label: label } },
        download_types: DownloadRoutingRule::DOWNLOAD_TYPES.map { |value| { value: value, label: value.titleize } },
        defaults: defaults_json,
        health: health_json
      }
    end

    private

    def parsed_address(url)
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end

    def hidden_address_parts?(address)
      address.nil? || address.userinfo.present? || address.query.present? || address.fragment.present? || address.opaque.present?
    end

    def shown_address(url)
      address = parsed_address(url)
      return "" if address.nil? || address.host.nil?

      address.class.new(address.scheme, nil, address.host, address.port, nil, address.path, nil, nil, nil).to_s
    end

    def client_json(client, rule_ids)
      {
        id: client.id.to_s,
        version: self.class.version(client),
        name: client.name,
        client_type: client.client_type,
        kind: kind_of(client),
        url: shown_address(client.url),
        url_hidden: hidden_address_parts?(parsed_address(client.url)),
        username: client.username.to_s,
        category: client.category.to_s,
        download_path: client.download_path.to_s,
        enabled: client.enabled?,
        priority: client.priority,
        torrent_verification_max_attempts: client.torrent_verification_max_attempts,
        torrent_verification_wait_time: client.torrent_verification_wait_time,
        password_saved: client.password.present?,
        api_key_saved: client.api_key.present?,
        rule_count: rule_ids.size,
        rule_ids: rule_ids
      }
    end

    def rule_json(rule)
      client = rule.download_client
      {
        id: rule.id.to_s,
        version: self.class.version(rule),
        provider: rule.provider,
        provider_label: rule.provider_name,
        indexer_name: rule.indexer_name,
        download_type: rule.download_type,
        client_id: client.id.to_s,
        client_name: client.name,
        client_enabled: client.enabled?,
        client_kind: kind_of(client),
        enabled: rule.enabled?
      }
    end

    def type_json(type)
      sample = DownloadClient.new(client_type: type)
      {
        value: type,
        label: TYPE_LABELS.fetch(type) { type.titleize },
        kind: kind_of(sample),
        authentication: sample.requires_authentication?,
        api_key: API_KEY_TYPES.include?(type),
        verification: VERIFICATION_TYPES.include?(type)
      }
    end

    def defaults_json
      sample = DownloadClient.new(category: "")
      {
        client_type: DownloadClient.client_types.keys.first,
        enabled: sample.enabled?,
        torrent_verification_max_attempts: sample.torrent_verification_max_attempts,
        torrent_verification_wait_time: sample.torrent_verification_wait_time
      }
    end

    def kind_of(client)
      client.usenet_client? ? "usenet" : "torrent"
    end

    def health_json
      health = SystemHealth.find_by(service: HEALTH_SERVICE)
      return { status: nil, message: nil, checked_at: nil } unless health

      { status: health.status, message: self.class.health_sentence(health.status), checked_at: health.last_check_at&.iso8601 }
    end
  end
end
