# frozen_string_literal: true

class DownloadRoutingRule < ApplicationRecord
  PROVIDERS = {
    "prowlarr" => "Prowlarr",
    "jackett" => "Jackett"
  }.freeze
  DOWNLOAD_TYPES = %w[torrent usenet].freeze

  belongs_to :download_client

  before_validation :normalize_fields

  validates :provider, presence: true, inclusion: { in: PROVIDERS.keys }
  validates :indexer_name, presence: true
  validates :normalized_indexer_name, presence: true
  validates :download_type, presence: true, inclusion: { in: DOWNLOAD_TYPES }
  validates :normalized_indexer_name, uniqueness: { scope: [ :provider, :download_type ], case_sensitive: false }
  validate :download_client_matches_download_type

  scope :enabled, -> { where(enabled: true) }
  scope :by_indexer, -> { order(provider: :asc, download_type: :asc, normalized_indexer_name: :asc) }

  class << self
    def for_result(search_result)
      return unless search_result.respond_to?(:from_indexer?) && search_result.from_indexer?

      indexer = normalize_indexer_name(search_result.indexer)
      type = search_result.download_type
      return if indexer.blank? || type.blank? || type == "direct"

      enabled.includes(:download_client).find_by(
        provider: provider_for_result(search_result),
        normalized_indexer_name: indexer,
        download_type: type
      )
    end

    def routed_client_for(search_result)
      rule = for_result(search_result)
      return unless rule&.download_client&.enabled?

      rule.download_client
    end

    def normalize_indexer_name(value)
      value.to_s.squish.downcase
    end

    private

    def provider_for_result(search_result)
      search_result.from_jackett? ? "jackett" : "prowlarr"
    end
  end

  def provider_name
    PROVIDERS.fetch(provider, provider.to_s.titleize)
  end

  private

  def normalize_fields
    self.provider = provider.to_s.strip.downcase
    self.download_type = download_type.to_s.strip.downcase
    self.indexer_name = indexer_name.to_s.squish
    self.normalized_indexer_name = self.class.normalize_indexer_name(indexer_name)
  end

  def download_client_matches_download_type
    return if download_client.blank? || download_type.blank?

    matches = case download_type
    when "torrent" then download_client.torrent_client?
    when "usenet" then download_client.usenet_client?
    else false
    end

    return if matches

    errors.add(:download_client, "must be a #{download_type} client")
  end
end
