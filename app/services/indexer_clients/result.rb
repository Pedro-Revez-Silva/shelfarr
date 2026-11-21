# frozen_string_literal: true

module IndexerClients
  Result = Data.define(
    :guid, :title, :indexer, :indexer_id, :size_bytes, :seeders, :leechers,
    :download_url, :magnet_url, :info_url, :published_at, :category_ids, :info_hash
  ) do
    def initialize(
      guid:, title:, indexer:, size_bytes:, seeders:, leechers:,
      download_url:, magnet_url:, info_url:, published_at:, category_ids: [], indexer_id: nil,
      info_hash: nil
    )
      super(
        guid:, title:, indexer:,
        indexer_id: Integer(indexer_id, exception: false),
        size_bytes:, seeders:, leechers:,
        download_url:, magnet_url:, info_url:, published_at:,
        category_ids: Array(category_ids).filter_map { |id| Integer(id, exception: false) }.uniq,
        info_hash: info_hash.is_a?(String) ? info_hash : nil
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
