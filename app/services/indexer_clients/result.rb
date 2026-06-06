# frozen_string_literal: true

module IndexerClients
  Result = Data.define(
    :guid, :title, :indexer, :size_bytes, :seeders, :leechers,
    :download_url, :magnet_url, :info_url, :published_at, :category_ids
  ) do
    def initialize(
      guid:, title:, indexer:, size_bytes:, seeders:, leechers:,
      download_url:, magnet_url:, info_url:, published_at:, category_ids: []
    )
      super(
        guid:, title:, indexer:, size_bytes:, seeders:, leechers:,
        download_url:, magnet_url:, info_url:, published_at:,
        category_ids: Array(category_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      )
    end

    def downloadable?
      download_url.present? || magnet_url.present?
    end

    def download_link
      magnet_url.presence || download_url
    end

    def size_human
      return nil unless size_bytes

      ActiveSupport::NumberHelper.number_to_human_size(size_bytes)
    end
  end
end
