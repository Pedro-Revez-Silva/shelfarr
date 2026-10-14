# frozen_string_literal: true

class DownloadClientSelector
  class NoClientAvailableError < StandardError; end

  def self.for_download(search_result)
    new(search_result).select
  end

  def self.for_torrent
    available_clients = DownloadClient.torrent_clients.enabled.by_priority

    if available_clients.empty?
      raise NoClientAvailableError, "No torrent download client configured"
    end

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

    routed_client = DownloadRoutingRule.routed_client_for(@search_result)
    ordered_clients = if routed_client && available_clients.include?(routed_client)
      [ routed_client ] + available_clients.reject { |client| client.id == routed_client.id }
    else
      available_clients
    end

    ordered_clients.each do |client|
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
