# frozen_string_literal: true

module DownloadClients
  # Base class for download client implementations
  # Subclasses should implement: add_torrent, torrent_info, list_torrents, test_connection
  class Base
    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class NotConfiguredError < Error; end

    # Data structure for torrent information
    TorrentInfo = Data.define(:hash, :name, :progress, :state, :size_bytes, :download_path) do
      def completed?
        state == :completed
      end

      def downloading?
        state == :downloading
      end

      def failed?
        state == :failed
      end
    end

    attr_reader :config

    def initialize(download_client)
      @config = download_client
    end

    # Add a torrent by URL or magnet link
    # Returns true on success, or hash with response data
    def add_torrent(url, options = {})
      raise NotImplementedError, "Subclass must implement add_torrent"
    end

    # Get info for a specific torrent by hash
    # Returns TorrentInfo or nil if not found
    def torrent_info(hash)
      raise NotImplementedError, "Subclass must implement torrent_info"
    end

    # List all torrents, optionally filtered
    # Returns array of TorrentInfo
    def list_torrents(filter = {})
      raise NotImplementedError, "Subclass must implement list_torrents"
    end

    # Test the connection to the client
    # Returns true if successful, false otherwise
    def test_connection
      raise NotImplementedError, "Subclass must implement test_connection"
    end

    # Remove a torrent by hash
    # delete_files: if true, also delete downloaded files
    # Returns true on success, false otherwise
    def remove_torrent(hash, delete_files: false)
      raise NotImplementedError, "Subclass must implement remove_torrent"
    end

    protected

    def base_url
      config.url
    end
  end
end
