# frozen_string_literal: true

module DownloadClients
  # Transmission RPC client
  class Transmission < Base
    TORRENT_FIELDS = %w[
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
      args = {
        filename: url
      }
      args[:paused] = options[:paused] unless options[:paused].nil?
      args["download-dir"] = options[:save_path] if options[:save_path].present?

      response = rpc_request("torrent-add", args: args)
      added = response.dig("torrent-added", "hashString")
      duplicate = response.dig("torrent-duplicate", "hashString")

      return added if added.present?
      return duplicate if duplicate.present?

      new_ids = torrent_ids - existing_ids
      new_ids.first
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    def torrent_info(hash)
      ensure_authenticated!

      response = rpc_request("torrent-get", ids: [hash], fields: TORRENT_FIELDS)
      return nil unless response && response["torrents"].is_a?(Array)

      info = response["torrents"].find { |torrent| torrent["hashString"] == hash.to_s }
      return nil unless info

      parse_torrent(info)
    end

    def list_torrents(filter = {})
      ensure_authenticated!

      ids = filter[:ids] || "all"
      response = rpc_request("torrent-get", ids: ids, fields: TORRENT_FIELDS)
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

      response = rpc_request("torrent-remove", ids: [hash], "delete-local-data": delete_files)
      !response.nil?
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    private

    def ensure_authenticated!
      authenticate! unless session_id.present?
    end

    def authenticate!
      # Authentication is validated on every request via session id.
      # We trigger one request to fetch session id.
      rpc_request("session-get")
      true
    end

    def rpc_request(method, args = {})
      attempts = 0

      loop do
        response = connection.post do |req|
          req.headers["X-Transmission-Session-Id"] = session_id if session_id.present?
          req.headers["Content-Type"] = "application/json"
          req.body = { method: method, arguments: args, tag: 1 }.to_json
        end

        if response.status == 409
          extract_session_id(response)
          attempts += 1
          next if attempts <= 1

          raise Base::Error, "Transmission session negotiation failed"
        end

        return parse_response(response, method)
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Transmission: #{e.message}"
    end

    def parse_response(response, method)
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

    def torrent_ids
      response = rpc_request("torrent-get", ids: "all", fields: [ "hashString" ])
      response.fetch("torrents", []).map { |torrent| torrent["hashString"] }.compact
    end

    def parse_torrent(data)
      Base::TorrentInfo.new(
        hash: data["hashString"],
        name: data["name"],
        progress: normalize_progress(data["percentDone"]),
        state: normalize_state(data["status"]),
        size_bytes: data["totalSize"],
        download_path: data["downloadDir"].to_s
      )
    end

    def normalize_progress(progress)
      return 0 if progress.blank?
      (progress.to_f * 100).round
    end

    def normalize_state(status)
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
      Faraday.new(url: base_url) do |f|
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
  end
end
