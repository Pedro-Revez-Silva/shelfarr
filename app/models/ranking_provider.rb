# frozen_string_literal: true

require "uri"

class RankingProvider < ApplicationRecord
  encrypts :api_key

  before_validation :normalize_url

  validates :name, presence: true, uniqueness: true
  validates :url, presence: true
  validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :timeout_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 120 }
  validate :url_is_http
  validate :url_private_network_access

  scope :enabled, -> { where(enabled: true) }
  scope :by_priority, -> { order(priority: :asc, name: :asc) }

  def client
    RankingProviderClient.new(self)
  end

  def test_connection
    client.test_connection
  end

  private

  def normalize_url
    self.url = url.to_s.strip.delete_suffix("/") if url.present?
  end

  def url_is_http
    uri = URI.parse(url.to_s)
    return if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.blank?

    errors.add(:url, "must be a valid http or https URL")
  rescue URI::InvalidURIError
    errors.add(:url, "must be a valid http or https URL")
  end

  def url_private_network_access
    return if allow_private_network?
    return if url.blank? || errors.include?(:url)

    host = URI.parse(url.to_s).host
    return unless OutboundUrlGuard.obviously_private_host?(host)

    errors.add(:url, "points to a private network address. Enable \"Allow private network\" if this provider runs on your local network.")
  rescue URI::InvalidURIError
    nil
  end
end
