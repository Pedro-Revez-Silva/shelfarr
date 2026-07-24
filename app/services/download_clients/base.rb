# frozen_string_literal: true

require "net/http"
require "uri"

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

    def resolve_guarded_torrent_source(raw_url)
      current_url = raw_url.to_s.strip.gsub(" ", "%20")

      10.times do
        endpoint = OutboundUrlGuard.validate!(current_url)
        response = Net::HTTP.start(
          endpoint.host,
          endpoint.port,
          use_ssl: endpoint.use_ssl?,
          ipaddr: endpoint.ipaddr,
          open_timeout: 30,
          read_timeout: 30
        ) do |http|
          request = Net::HTTP::Get.new(endpoint.uri)
          request["User-Agent"] = "Shelfarr/1.0"
          http.request(request)
        end

        if response.is_a?(Net::HTTPRedirection)
          location = response["Location"]
          raise Error, "Torrent source redirect missing Location" if location.blank?

          current_url = URI.join(endpoint.uri, location).to_s
          return { url: current_url } if current_url.start_with?("magnet:")

          next
        end

        if response.code.to_i == 429 || response.code.to_i >= 500
          raise ConnectionError, "Torrent source returned HTTP #{response.code}"
        end

        magnet = extract_magnet_from_body(response.body.to_s)
        return { url: magnet } if magnet.present?
        return { url: current_url, torrent_data: response.body } if response.is_a?(Net::HTTPSuccess) && response.body.present?

        return { url: current_url }
      end

      raise Error, "Torrent source exceeded redirect limit"
    rescue OutboundUrlGuard::BlockedUrlError => e
      raise Error, "Refused torrent source URL: #{e.message}"
    rescue URI::Error => e
      raise Error, "Invalid torrent source redirect: #{e.message}"
    rescue SocketError, IOError, EOFError, Timeout::Error, Net::ProtocolError, OpenSSL::SSL::SSLError, SystemCallError => e
      raise ConnectionError, "Failed to fetch torrent source: #{e.message}"
    end
  end
end
