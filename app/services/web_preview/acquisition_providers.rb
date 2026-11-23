# frozen_string_literal: true

module WebPreview
  class AcquisitionProviders
    def self.version(provider)
      provider.updated_at.utc.iso8601(6)
    end

    def representation
      providers = AcquisitionProvider.by_priority.to_a
      {
        providers: providers.each_with_index.map { |provider, index| provider_json(provider, index + 1) },
        defaults: defaults_json
      }
    end

    private

    def provider_json(provider, position)
      address = parsed_address(provider.url)
      {
        id: provider.id.to_s,
        version: self.class.version(provider),
        name: provider.name,
        url: shown_address(address),
        url_hidden: address.nil? || address.query.present? || address.fragment.present? || address.userinfo.present?,
        api_key_saved: provider.api_key.present?,
        enabled: provider.enabled?,
        allow_private_network: provider.allow_private_network?,
        supports_ebooks: provider.supports_ebooks?,
        supports_audiobooks: provider.supports_audiobooks?,
        supports_comicbooks: provider.supports_comicbooks?,
        timeout_seconds: provider.timeout_seconds,
        priority: provider.priority,
        position: position
      }
    end

    def defaults_json
      sample = AcquisitionProvider.new(AcquisitionProvider::FORM_DEFAULTS)
      {
        enabled: sample.enabled?,
        allow_private_network: sample.allow_private_network?,
        supports_ebooks: sample.supports_ebooks?,
        supports_audiobooks: sample.supports_audiobooks?,
        supports_comicbooks: sample.supports_comicbooks?,
        timeout_seconds: sample.timeout_seconds
      }
    end

    def parsed_address(url)
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end

    def shown_address(address)
      return "" if address.nil? || address.host.nil?

      address.class.new(address.scheme, nil, address.host, address.port, nil, address.path, nil, nil, nil).to_s
    end
  end
end
