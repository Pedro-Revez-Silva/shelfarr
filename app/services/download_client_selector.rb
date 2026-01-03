# frozen_string_literal: true

# Selects the best available download client based on download type and priority
class DownloadClientSelector
  class NoClientAvailableError < StandardError; end

  def self.for_download(search_result)
    new(search_result).select
  end

  # Select a torrent client directly (for Anna's Archive downloads)
  def self.for_torrent
    available_clients = DownloadClient.torrent_clients.enabled.by_priority

    if available_clients.empty?
      raise NoClientAvailableError, "No torrent download client configured"
    end

    # Try each client in priority order until one succeeds connection test
    available_clients.each do |client|
      return client if client.test_connection
    end

    # If no client passed connection test, raise error
    raise NoClientAvailableError, "No torrent client available (all failed connection test)"
  end

  def initialize(search_result)
    @search_result = search_result
  end

  def select
    clients = if @search_result.usenet?
      DownloadClient.usenet_clients
    else
      DownloadClient.torrent_clients
    end

    available_clients = clients.enabled.by_priority

    if available_clients.empty?
      raise NoClientAvailableError, "No #{download_type} download client configured"
    end

    # Try each client in priority order until one succeeds connection test
    available_clients.each do |client|
      return client if client.test_connection
    end

    # If no client passed connection test, raise error
    raise NoClientAvailableError, "No #{download_type} client available (all failed connection test)"
  end

  private

  def download_type
    @search_result.usenet? ? "usenet" : "torrent"
  end
end
