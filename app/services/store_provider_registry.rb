# frozen_string_literal: true

class StoreProviderRegistry
  CONFIGURATION_SETTINGS = {
    ebooks_com_enabled: "ebooks_com",
    ebooks_com_country_code: "ebooks_com"
  }.freeze

  Provider = Data.define(:key, :name, :client, :book_types, :market_resolver) do
    def supports?(book_type)
      book_types.include?(book_type.to_s)
    end

    def market
      market_resolver&.call.to_s.strip.upcase.presence
    end
  end

  PROVIDERS = [
    Provider.new(
      key: "ebooks_com",
      name: "eBooks.com",
      client: EbooksComClient,
      book_types: %w[ebook],
      market_resolver: -> { EbooksComClient.buyer_country_code }
    )
  ].freeze

  class << self
    def enabled_for(book_type)
      PROVIDERS.select { |provider| provider.supports?(book_type) && provider.client.configured? }
    end

    def visible_offers_for(request)
      providers = enabled_for(request.book.book_type)
      return request.store_offers.none if providers.empty? || request.completed?

      providers.reduce(request.store_offers.none) do |scope, provider|
        provider_scope = request.store_offers.where(provider: provider.key)
        provider_scope = provider_scope.where(market: provider.market) if provider.market.present?
        scope.or(provider_scope)
      end.fresh
    end

    def awaiting_requests_without_visible_offers
      providers = PROVIDERS.select { |provider| provider.client.configured? }
      return Request.awaiting_purchase if providers.empty?

      offers = StoreOffer.joins(request: :book)
      eligible_offers = providers.reduce(offers.none) do |scope, provider|
        provider_scope = offers.where(
          provider: provider.key,
          books: { book_type: provider.book_types }
        )
        if provider.market.present?
          provider_scope = provider_scope.where(market: provider.market)
        end
        scope.or(provider_scope)
      end

      Request.awaiting_purchase.where.not(id: eligible_offers.fresh.select(:request_id))
    end

    def setting_changed!(key, previous_value:, current_value:)
      provider_key = CONFIGURATION_SETTINGS[key.to_sym]
      return unless provider_key
      return if normalized_configuration_value(key, previous_value) == normalized_configuration_value(key, current_value)
      return unless StoreOffer.table_exists?

      offers = StoreOffer.where(provider: provider_key)
      awaiting_request_ids = if Request.table_exists?
        offers.joins(:request)
          .where(requests: { status: Request.statuses[:awaiting_purchase] })
          .distinct
          .pluck(:request_id)
      else
        []
      end
      offers.delete_all
      Request.where(id: awaiting_request_ids, status: :awaiting_purchase).update_all(
        status: Request.statuses[:pending],
        attention_needed: false,
        issue_description: nil,
        next_retry_at: nil,
        updated_at: Time.current
      )
    end

    private

    def normalized_configuration_value(key, value)
      case key.to_sym
      when :ebooks_com_enabled
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value.to_s.strip.upcase
      end
    end
  end
end
