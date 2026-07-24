# frozen_string_literal: true

require "net/http"
require "uri"
require "bencode"

module DownloadClients
  # Base class for download client implementations
  # Subclasses should implement: add_torrent, torrent_info, list_torrents, test_connection
  class Base
    MAX_GUARDED_TORRENT_BYTES = 10.megabytes
    MAX_GUARDED_TORRENT_CONTENT_BYTES = 2.gigabytes
    MAX_GUARDED_TORRENT_FILES = 2_000
    MAX_GUARDED_TORRENT_DURATION = 2.minutes
    MAX_BENCODE_DEPTH = 64
    MAX_BENCODE_NODES = 100_000
    MAX_BENCODE_INTEGER_DIGITS = 64
    MAX_UNTRUSTED_MAGNET_BYTES = 2.kilobytes
    MAX_UNTRUSTED_MAGNET_PARAMS = 16
    MAX_TORRENT_PIECE_BYTES = 16.megabytes
    MAX_TORRENT_NAME_BYTES = 1.kilobyte
    MAX_TORRENT_PATH_DEPTH = 32

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
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_GUARDED_TORRENT_DURATION

      10.times do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise ConnectionError, "Torrent source exceeded its time limit"
        end
        endpoint = OutboundUrlGuard.validate!(current_url)
        unless endpoint.scheme == "https"
          raise Error, "Refused insecure torrent source URL"
        end

        response = nil
        body = +""
        Net::HTTP.start(
          endpoint.host,
          endpoint.port,
          use_ssl: endpoint.use_ssl?,
          ipaddr: endpoint.ipaddr,
          open_timeout: 30,
          read_timeout: 30
        ) do |http|
          request = Net::HTTP::Get.new(endpoint.uri)
          request["User-Agent"] = "Shelfarr/1.0"
          http.request(request) do |incoming|
            response = incoming
            next if incoming.is_a?(Net::HTTPRedirection)
            status = incoming.code.to_i
            if status.in?([ 408, 425, 429 ]) || status >= 500
              raise ConnectionError, "Torrent source returned HTTP #{incoming.code}"
            end
            next unless incoming.is_a?(Net::HTTPSuccess)

            content_length = incoming["Content-Length"].to_i if incoming["Content-Length"].present?
            if content_length && content_length > MAX_GUARDED_TORRENT_BYTES
              raise Error, "Torrent source response exceeds its size limit"
            end
            incoming.read_body do |chunk|
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                raise ConnectionError, "Torrent source exceeded its time limit"
              end
              if body.bytesize + chunk.bytesize > MAX_GUARDED_TORRENT_BYTES
                raise Error, "Torrent source response exceeds its size limit"
              end

              body << chunk
            end
          end
        end

        if response.is_a?(Net::HTTPRedirection)
          location = response["Location"]
          raise Error, "Torrent source redirect missing Location" if location.blank?

          current_url = URI.join(endpoint.uri, location).to_s
          return { url: sanitize_untrusted_magnet!(current_url) } if current_url.start_with?("magnet:")

          next
        end

        return { url: current_url } unless response.is_a?(Net::HTTPSuccess)

        magnet = extract_magnet_from_body(body)
        return { url: sanitize_untrusted_magnet!(magnet) } if magnet.present?
        return { url: current_url, torrent_data: sanitize_untrusted_torrent_data!(body) } if body.present?

        return { url: current_url }
      end

      raise Error, "Torrent source exceeded redirect limit"
    rescue OutboundUrlGuard::BlockedUrlError
      raise Error, "Refused unsafe torrent source URL"
    rescue URI::Error
      raise Error, "Invalid torrent source redirect"
    rescue SocketError, IOError, EOFError, Timeout::Error, Net::ProtocolError, OpenSSL::SSL::SSLError, SystemCallError
      raise ConnectionError, "Failed to fetch torrent source"
    end

    def sanitize_untrusted_magnet!(url)
      if url.to_s.bytesize > MAX_UNTRUSTED_MAGNET_BYTES
        raise Error, "Torrent source returned an oversized magnet link"
      end

      uri = URI.parse(url.to_s)
      raise Error, "Torrent source returned an invalid magnet link" unless uri.scheme == "magnet"

      params = URI.decode_www_form(uri.query.to_s)
      if params.size > MAX_UNTRUSTED_MAGNET_PARAMS
        raise Error, "Torrent source returned an oversized magnet link"
      end
      xt = params.filter_map do |key, value|
        value if key == "xt" && value.match?(/\Aurn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})\z/i)
      end.first
      info_hash = MagnetLink.info_hash("magnet:?xt=#{URI.encode_www_form_component(xt.to_s)}")
      raise Error, "Torrent source returned an invalid magnet link" unless info_hash

      "magnet:?xt=urn:btih:#{info_hash}"
    rescue URI::InvalidURIError, ArgumentError
      raise Error, "Torrent source returned an invalid magnet link"
    end

    def sanitize_untrusted_torrent_data!(torrent_data)
      validate_bencode_limits!(torrent_data)
      metadata = BEncode.load(torrent_data.dup)
      info = metadata["info"] if metadata.is_a?(Hash)
      raise Error, "Torrent source did not return a valid torrent file" unless info.is_a?(Hash)
      if info["meta version"] || info["file tree"]
        raise Error, "BitTorrent v2 sources are not supported for guarded downloads"
      end
      private_flag = info.fetch("private", 0)
      unless private_flag.is_a?(Integer) && private_flag.in?([ 0, 1 ])
        raise Error, "Torrent source did not return valid private metadata"
      end
      if private_flag == 1
        raise Error, "Private torrents are not supported for guarded downloads"
      end

      lengths = validate_v1_torrent_info!(info)
      if lengths.any?(&:negative?) || lengths.sum > MAX_GUARDED_TORRENT_CONTENT_BYTES
        raise Error, "Torrent source content exceeds its size limit"
      end

      { "info" => info }.bencode
    rescue BEncode::DecodeError, BEncode::EncodeError, KeyError, TypeError, ArgumentError
      raise Error, "Torrent source did not return a valid torrent file"
    end

    def validate_v1_torrent_info!(info)
      if info.key?("name.utf-8") || info.key?("attr") || info.key?("symlink path") || info.key?("symlink path.utf-8")
        raise Error, "Torrent source contains unsupported alternate or link metadata"
      end

      name = info["name"]
      unless valid_torrent_path_component?(name) && name.bytesize <= MAX_TORRENT_NAME_BYTES
        raise Error, "Torrent source did not return valid name metadata"
      end

      has_files = info.key?("files")
      has_length = info.key?("length")
      unless has_files ^ has_length
        raise Error, "Torrent source did not return a valid v1 file layout"
      end

      lengths = if has_files
        files = info["files"]
        unless files.is_a?(Array) && files.any? && files.size <= MAX_GUARDED_TORRENT_FILES
          raise Error, "Torrent source did not return valid file metadata"
        end
        effective_paths = {}
        lengths = files.map do |file|
          raise Error, "Torrent source did not return valid file metadata" unless file.is_a?(Hash)
          if file.key?("path.utf-8") || file.key?("attr") || file.key?("symlink path") || file.key?("symlink path.utf-8")
            raise Error, "Torrent source contains unsupported alternate or link metadata"
          end

          path = file["path"]
          unless path.is_a?(Array) && path.any? && path.size <= MAX_TORRENT_PATH_DEPTH &&
              path.all? { |component| valid_torrent_path_component?(component) }
            raise Error, "Torrent source did not return valid file paths"
          end
          effective_path = path.join("/")
          raise Error, "Torrent source contains duplicate file paths" if effective_paths.key?(effective_path)

          effective_paths[effective_path] = true
          length = file["length"]
          raise Error, "Torrent source did not return valid file metadata" unless length.is_a?(Integer)

          length
        end
        effective_paths.each_key do |path|
          parts = path.split("/")
          (1...parts.length).each do |length|
            ancestor = parts.first(length).join("/")
            if effective_paths.key?(ancestor)
              raise Error, "Torrent source contains conflicting file paths"
            end
          end
        end
        lengths
      else
        length = info["length"]
        raise Error, "Torrent source did not return valid file metadata" unless length.is_a?(Integer)

        [ length ]
      end

      total_bytes = lengths.sum
      piece_length = info["piece length"]
      pieces = info["pieces"]
      unless total_bytes.positive? && piece_length.is_a?(Integer) && piece_length.between?(1, MAX_TORRENT_PIECE_BYTES) &&
          pieces.is_a?(String) && pieces.bytesize == ((total_bytes + piece_length - 1) / piece_length) * 20
        raise Error, "Torrent source did not return valid piece metadata"
      end

      lengths
    end

    def valid_torrent_path_component?(component)
      return false unless component.is_a?(String)

      value = component.dup
      value.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::ASCII_8BIT
      value.valid_encoding? && value.present? && value.bytesize <= 255 &&
        !value.in?([ ".", ".." ]) && !value.match?(/[\\\/\0[:cntrl:]]/)
    end

    def validate_bencode_limits!(data)
      index = 0
      depth = 0
      nodes = 0

      while index < data.bytesize
        byte = data.getbyte(index)
        case byte
        when "d".ord, "l".ord
          depth += 1
          raise Error, "Torrent source metadata is nested too deeply" if depth > MAX_BENCODE_DEPTH
          index += 1
        when "e".ord
          depth -= 1
          raise Error, "Torrent source metadata is malformed" if depth.negative?
          index += 1
        when "i".ord
          terminator = data.index("e", index + 1)
          raise Error, "Torrent source metadata is malformed" unless terminator

          integer = data.byteslice(index + 1, terminator - index - 1)
          if integer.delete_prefix("-").bytesize > MAX_BENCODE_INTEGER_DIGITS
            raise Error, "Torrent source integer exceeds its size limit"
          end
          unless integer.match?(/\A(?:0|-?[1-9]\d*)\z/)
            raise Error, "Torrent source metadata is malformed"
          end
          index = terminator + 1
        when 48..57
          separator = data.index(":", index)
          raise Error, "Torrent source metadata is malformed" unless separator

          length_text = data.byteslice(index, separator - index)
          unless length_text.match?(/\A(?:0|[1-9]\d*)\z/) && length_text.bytesize <= 10
            raise Error, "Torrent source metadata is malformed"
          end
          length = Integer(length_text)
          raise Error, "Torrent source scalar exceeds its size limit" if length > MAX_GUARDED_TORRENT_BYTES

          index = separator + 1 + length
          raise Error, "Torrent source metadata is truncated" if index > data.bytesize
        else
          raise Error, "Torrent source metadata is malformed"
        end

        nodes += 1 unless byte == "e".ord
        raise Error, "Torrent source metadata contains too many values" if nodes > MAX_BENCODE_NODES
      end

      raise Error, "Torrent source metadata is malformed" unless depth.zero?
    end
  end
end
