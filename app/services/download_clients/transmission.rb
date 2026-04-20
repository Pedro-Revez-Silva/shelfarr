# frozen_string_literal: true

require "base64"
require "bencode"

module DownloadClients
  # Transmission RPC client
  class Transmission < Base
    class LegacyProtocolRequired < StandardError; end

    JSONRPC_TORRENT_FIELDS = %w[
      id
      name
      hash_string
      percent_done
      status
      total_size
      download_dir
      error
      error_string
    ].freeze

    LEGACY_TORRENT_FIELDS = %w[
      id
      name
      hashString
      percentDone
      status
      totalSize
      downloadDir
      error
      errorString
    ].freeze

    def add_torrent(url, options = {})
      ensure_authenticated!

      existing_ids = torrent_ids
      prepared = prepare_torrent_submission(url)
      args = {}
      args[:metainfo] = prepared[:metainfo] if prepared[:metainfo].present?
      args[:filename] = prepared[:url] if prepared[:metainfo].blank?
      args[:paused] = options[:paused] unless options[:paused].nil?
      args[:download_dir] = options[:save_path] if options[:save_path].present?

      response = rpc_request("torrent-add", args)
      added = transmission_value(response, "torrent_added", "torrent-added")
      duplicate = transmission_value(response, "torrent_duplicate", "torrent-duplicate")
      added_hash = transmission_value(added, "hash_string", "hashString")
      duplicate_hash = transmission_value(duplicate, "hash_string", "hashString")

      return added_hash if added_hash.present?
      return duplicate_hash if duplicate_hash.present?

      new_ids = torrent_ids - existing_ids
      new_ids.first
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    def torrent_info(hash)
      ensure_authenticated!

      response = rpc_request("torrent-get", ids: [hash], fields: torrent_fields)
      return nil unless response && response["torrents"].is_a?(Array)

      info = response["torrents"].find { |torrent| transmission_value(torrent, "hash_string", "hashString") == hash.to_s }
      return nil unless info

      parse_torrent(info)
    end

    def list_torrents(filter = {})
      ensure_authenticated!

      ids = filter[:ids] || "all"
      response = rpc_request("torrent-get", ids: ids, fields: torrent_fields)
      torrents = response&.fetch("torrents", []) || []

      torrents.map { |torrent| parse_torrent(torrent) }
    end

    def test_connection
      ensure_authenticated!

      rpc_request("session-get")
      true
    rescue Base::Error, Base::AuthenticationError, Faraday::Error => e
      Rails.logger.warn "[Transmission] Connection test failed: #{e.message}"
      false
    end

    def remove_torrent(hash, delete_files: false)
      ensure_authenticated!

      response = rpc_request("torrent-remove", ids: [hash], delete_local_data: delete_files)
      !response.nil?
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    private

    def ensure_authenticated!
      authenticate! unless session_id.present? && protocol_mode.present?
    end

    def authenticate!
      # Authentication is validated on every request via session id.
      # We trigger one request to negotiate the current RPC protocol and fetch session id.
      rpc_request("session-get")
      true
    end

    def rpc_request(method, args = {})
      errors = []

      candidate_protocols.each do |protocol|
        begin
          response = rpc_request_with_protocol(method, args, protocol)
          store_protocol!(protocol)
          return response
        rescue LegacyProtocolRequired
          clear_protocol!
        rescue Base::AuthenticationError => e
          raise e
        rescue Base::Error => e
          errors << e
          raise e if protocol_mode.present? || protocol == :legacy
        end
      end

      raise errors.last if errors.any?

      raise Base::Error, "Transmission request failed without a usable protocol"
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    def rpc_request_with_protocol(method, args, protocol)
      attempts = 0

      loop do
        response = connection.post do |req|
          req.headers["X-Transmission-Session-Id"] = session_id if session_id.present?
          req.headers["Content-Type"] = "application/json"
          req.body = request_payload(protocol, method, args).to_json
        end

        if response.status == 409
          extract_session_id(response)
          attempts += 1
          next if attempts <= 1

          raise Base::Error, "Transmission session negotiation failed"
        end

        return parse_response(response, method, protocol)
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    def parse_response(response, method, protocol)
      if response.status == 401 || response.status == 403
        clear_session!
        raise Base::AuthenticationError, "Transmission authentication failed: #{response.status}"
      end

      unless response.status == 200
        raise Base::Error, "Transmission API error: #{response.status}"
      end

      body = response.body
      unless body.is_a?(Hash)
        raise Base::Error, "Transmission API returned unexpected response format"
      end

      if body["jsonrpc"] == "2.0"
        return parse_jsonrpc_response(body, method)
      end

      raise LegacyProtocolRequired if protocol == :jsonrpc

      if body["result"] != "success"
        message = body["result"]
        if message == "session"
          clear_session!
          raise Base::AuthenticationError, "Transmission session negotiation required"
        end
        raise Base::Error, "Transmission API error for #{method}: #{message}"
      end

      body["arguments"] || {}
    end

    def parse_jsonrpc_response(body, method)
      if body["error"].is_a?(Hash)
        error = body["error"]
        message = error["message"].presence || "Unknown error"
        details = error["data"].is_a?(Hash) ? error["data"]["error_string"].presence : nil
        raise Base::Error, "Transmission API error for #{method.tr('-', '_')}: #{[message, details].compact.join(': ')}"
      end

      result = body["result"]
      unless result.is_a?(Hash)
        raise Base::Error, "Transmission API returned unexpected JSON-RPC response format"
      end

      result
    end

    def extract_session_id(response)
      session_id = response.headers["x-transmission-session-id"] ||
        response.headers["X-Transmission-Session-Id"]
      return unless session_id.present?

      clear_session!
      Thread.current[:transmission_sessions] ||= {}
      Thread.current[:transmission_sessions][config.id] = session_id
    end

    def clear_session!
      Thread.current[:transmission_sessions]&.delete(config.id)
    end

    def protocol_mode
      Thread.current[:transmission_protocols]&.[](config.id)
    end

    def store_protocol!(protocol)
      Thread.current[:transmission_protocols] ||= {}
      Thread.current[:transmission_protocols][config.id] = protocol
    end

    def clear_protocol!
      Thread.current[:transmission_protocols]&.delete(config.id)
    end

    def candidate_protocols
      protocol_mode.present? ? [ protocol_mode.to_sym ] : [ :jsonrpc, :legacy ]
    end

    def request_payload(protocol, method, args)
      if protocol == :jsonrpc
        {
          jsonrpc: "2.0",
          method: method.tr("-", "_"),
          params: args,
          id: 1
        }
      else
        {
          method: method,
          arguments: args,
          tag: 1
        }
      end
    end

    def torrent_ids
      response = rpc_request("torrent-get", ids: "all", fields: [ torrent_hash_field ])
      response.fetch("torrents", []).map { |torrent| transmission_value(torrent, "hash_string", "hashString") }.compact
    end

    def torrent_fields
      protocol_mode.to_sym == :legacy ? LEGACY_TORRENT_FIELDS : JSONRPC_TORRENT_FIELDS
    end

    def torrent_hash_field
      protocol_mode.to_sym == :legacy ? "hashString" : "hash_string"
    end

    def prepare_torrent_submission(url)
      return { url: url } if url.blank? || url.start_with?("magnet:")

      source = resolve_torrent_source(url)
      return { url: url } if source.blank?

      resolved_url = source[:url].presence || url
      return { url: resolved_url } if resolved_url.start_with?("magnet:")

      torrent_data = source[:torrent_data]
      return { url: resolved_url } unless valid_torrent_data?(torrent_data)

      { metainfo: Base64.strict_encode64(torrent_data) }
    end

    def resolve_torrent_source(raw_url)
      normalized_url = normalized_torrent_url(raw_url)
      return nil unless normalized_url

      current_url = normalized_url
      max_redirects = 10

      max_redirects.times do
        response = torrent_download_connection.get do |req|
          req.url current_url
        end

        location = response.headers["location"]
        if response.status.between?(300, 399) && location.present?
          redirected_url = absolutize_redirect_url(current_url, location)
          return { url: current_url } if redirected_url.blank?
          return { url: redirected_url } if redirected_url.start_with?("magnet:")

          current_url = redirected_url
          next
        end

        magnet = extract_magnet_from_body(response.body.to_s)
        return { url: magnet } if magnet.present?
        return { url: current_url, torrent_data: response.body } if response.success? && response.body.present?

        return { url: current_url }
      end

      Rails.logger.warn "[Transmission] Too many redirects while fetching torrent: #{normalized_url.truncate(100)}"
      { url: current_url }
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Transmission] Invalid torrent URL: #{e.message}"
      nil
    rescue Faraday::Error => e
      Rails.logger.warn "[Transmission] Failed to download torrent file for direct upload: #{e.message}"
      nil
    end

    def valid_torrent_data?(torrent_data)
      return false if torrent_data.blank?

      parsed = BEncode.load(torrent_data.dup)
      parsed.is_a?(Hash) && parsed["info"].is_a?(Hash)
    rescue BEncode::DecodeError
      false
    end

    def normalized_torrent_url(raw_url)
      return nil if raw_url.blank?

      uri = URI.parse(raw_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.to_s
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Transmission] Invalid torrent URL: #{e.message}"
      nil
    end

    def torrent_download_connection
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 30
        f.options.open_timeout = 10
        f.headers["Accept"] = "*/*"
        f.headers["User-Agent"] = "Shelfarr/1.0"
      end
    end

    def absolutize_redirect_url(base_url, location)
      return location if location.start_with?("magnet:")

      resolved = URI.join(base_url, location).to_s
      uri = URI.parse(resolved)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      resolved
    rescue URI::InvalidURIError
      nil
    end

    def extract_magnet_from_body(body)
      body.match(/magnet:\?[^\s"'<>]+/i)&.to_s
    end

    def parse_torrent(data)
      Base::TorrentInfo.new(
        hash: transmission_value(data, "hash_string", "hashString"),
        name: data["name"],
        progress: normalize_progress(transmission_value(data, "percent_done", "percentDone")),
        state: normalize_state(data["status"], error: data["error"]),
        size_bytes: transmission_value(data, "total_size", "totalSize"),
        download_path: transmission_value(data, "download_dir", "downloadDir").to_s
      )
    end

    def transmission_value(data, *keys)
      return nil unless data.is_a?(Hash)

      keys.each do |key|
        value = data[key]
        return value unless value.nil?
      end

      nil
    end

    def normalize_progress(progress)
      return 0 if progress.blank?
      (progress.to_f * 100).round
    end

    def normalize_state(status, error: nil)
      return :failed if error.to_i == 3

      case status.to_i
      when 0
        :paused
      when 1, 2
        :queued
      when 3
        :queued
      when 4
        :downloading
      when 5
        :queued
      when 6
        :completed
      else
        :downloading
      end
    end

    def connection
      Faraday.new(url: rpc_url) do |f|
        f.request :json
        if config.username.present? || config.password.present?
          f.request :authorization, :basic, config.username.to_s, config.password.to_s
        end
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def session_id
      Thread.current[:transmission_sessions]&.[](config.id)
    end

    def rpc_url
      uri = URI.parse(base_url)
      path = uri.path.to_s

      if path.blank? || path == "/"
        uri.path = "/transmission/rpc"
      elsif path.end_with?("/transmission/rpc/")
        uri.path = path.delete_suffix("/")
      end

      uri.to_s
    rescue URI::InvalidURIError
      base_url
    end
  end
end
