# frozen_string_literal: true

require "uri"

class AcquisitionProvider < ApplicationRecord
  encrypts :api_key

  has_many :search_results, dependent: :nullify

  before_validation :normalize_url

  validates :name, presence: true, uniqueness: true
  validates :url, presence: true
  validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :timeout_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 120 }
  validate :url_is_http
  validate :url_private_network_access
  validate :supports_at_least_one_media_type

  scope :enabled, -> { where(enabled: true) }
  scope :by_priority, -> { order(priority: :asc, name: :asc) }
  scope :for_book_type, ->(book_type) {
    case book_type&.to_s
    when "ebook"
      where(supports_ebooks: true)
    when "audiobook"
      where(supports_audiobooks: true)
    when "comicbook"
      where(supports_comicbooks: true)
    else
      all
    end
  }

  def client
    CustomAcquisitionProviderClient.new(self)
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

  def supports_at_least_one_media_type
    return if supports_ebooks? || supports_audiobooks? || supports_comicbooks?

    errors.add(:base, "Provider must support ebooks, audiobooks, or Comics & Manga")
  end
end
