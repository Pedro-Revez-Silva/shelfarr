# frozen_string_literal: true

class DownloadClient < ApplicationRecord
  encrypts :password, :api_key

  enum :client_type, {
    qbittorrent: "qbittorrent",
    decypharr: "decypharr",
    sabnzbd: "sabnzbd",
    nzbget: "nzbget",
    deluge: "deluge",
    transmission: "transmission"
  }

  has_many :downloads, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :client_type, presence: true
  validates :url, presence: true
  validates :priority, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :torrent_verification_max_attempts,
    numericality: { only_integer: true, greater_than: 0 }
  validates :torrent_verification_wait_time,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :enabled, -> { where(enabled: true) }
  scope :by_priority, -> { order(priority: :asc) }
  scope :torrent_clients, -> { where(client_type: [ :qbittorrent, :decypharr, :deluge, :transmission ]) }
  scope :usenet_clients, -> { where(client_type: [ :sabnzbd, :nzbget ]) }

  def adapter
    case client_type
    when "qbittorrent"
      DownloadClients::Qbittorrent.new(self)
    when "decypharr"
      DownloadClients::Decypharr.new(self)
    when "sabnzbd"
      DownloadClients::Sabnzbd.new(self)
    when "nzbget"
      DownloadClients::Nzbget.new(self)
    when "deluge"
      DownloadClients::Deluge.new(self)
    when "transmission"
      DownloadClients::Transmission.new(self)
    end
  end
  alias_method :client_instance, :adapter

  def test_connection
    adapter.test_connection
  rescue StandardError
    false
  end

  def torrent_client?
    qbittorrent? || decypharr? || deluge? || transmission?
  end

  def usenet_client?
    sabnzbd? || nzbget?
  end

  def requires_authentication?
    qbittorrent? || decypharr? || nzbget? || deluge? || transmission?
  end

  def qbittorrent_compatible?
    qbittorrent? || decypharr?
  end
end
