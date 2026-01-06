# frozen_string_literal: true

module DownloadClients
  # qBittorrent WebUI API client
  # https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)
  class Qbittorrent < Base
    # Add a torrent by URL or magnet link
    # Returns the torrent hash on success, nil on failure
    def add_torrent(url, options = {})
      ensure_authenticated!

      # For magnet links, extract hash upfront (more reliable than querying after)
      hash_from_magnet = extract_hash_from_magnet(url) if url.start_with?("magnet:")

      # For URL-based torrents, capture existing hashes before adding
      # so we can detect the new one by comparing before/after
      existing_hashes = hash_from_magnet.present? ? nil : fetch_all_torrent_hashes

      params = { urls: url }
      params[:category] = config.category if config.category.present?
      params[:savepath] = options[:save_path] if options[:save_path].present?
      params[:paused] = options[:paused] ? "true" : "false" if options.key?(:paused)

      response = connection.post("/api/v2/torrents/add", params)

      case response.status
      when 200
        # qBittorrent returns "Ok." on success or empty body
        return nil unless response.body == "Ok." || response.body.blank?

        # Return hash from magnet if available
        return hash_from_magnet if hash_from_magnet.present?

        # For .torrent URLs, detect the newly added torrent by comparing hashes
        find_newly_added_torrent_hash(existing_hashes)
      when 401, 403
        clear_session!
        raise Base::AuthenticationError, "qBittorrent authentication failed"
      else
        Rails.logger.error "[Qbittorrent] Failed to add torrent: #{response.status} - #{response.body}"
        nil
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent: #{e.message}"
    end

    # Get info for a specific torrent by hash
    def torrent_info(hash)
      ensure_authenticated!

      response = connection.get("/api/v2/torrents/info", { hashes: hash })

      handle_response(response) do |data|
        return nil if data.blank?

        parse_torrent(data.first)
      end
    end

    # List all torrents
    def list_torrents(filter = {})
      ensure_authenticated!

      response = connection.get("/api/v2/torrents/info", filter)

      handle_response(response) do |data|
        Array(data).map { |t| parse_torrent(t) }
      end
    end

    # Test connection
    def test_connection
      ensure_authenticated!
      true
    rescue Error
      false
    end

    private

    def extract_hash_from_magnet(url)
      match = url.match(/btih:([a-fA-F0-9]+)/i)
      match[1]&.downcase if match
    end

    # Fetch all current torrent hashes as a Set for efficient comparison
    def fetch_all_torrent_hashes
      response = connection.get("/api/v2/torrents/info")
      return Set.new unless response.status == 200

      Set.new(Array(response.body).map { |t| t["hash"] })
    end

    # Poll for a newly added torrent by comparing against existing hashes
    # This is more reliable than querying "most recent" which can race with other downloads
    def find_newly_added_torrent_hash(existing_hashes)
      max_wait_seconds = 30

      max_wait_seconds.times do |attempt|
        sleep 1

        current_hashes = fetch_all_torrent_hashes
        new_hashes = current_hashes - existing_hashes

        if new_hashes.any?
          hash = new_hashes.first
          Rails.logger.info "[Qbittorrent] Detected new torrent hash after #{attempt + 1}s: #{hash}"
          return hash
        end
      end

      Rails.logger.warn "[Qbittorrent] No new torrent detected after #{max_wait_seconds} seconds"
      nil
    end

    def ensure_authenticated!
      authenticate! unless session_valid?
    end

    def authenticate!
      auth_response = Faraday.post(
        "#{base_url}/api/v2/auth/login",
        { username: username, password: password }
      )

      if auth_response.status == 200 && auth_response.body == "Ok."
        # Extract SID cookie from response
        cookie = auth_response.headers["set-cookie"]
        match = cookie&.match(/SID=([^;]+)/)
        if match
          session_key[:sid] = match[1]
          Rails.logger.debug "[Qbittorrent] Authenticated successfully to #{config.name}"
        else
          raise Base::AuthenticationError, "No session cookie received from qBittorrent"
        end
      else
        raise Base::AuthenticationError, "qBittorrent login failed: #{auth_response.body}"
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent: #{e.message}"
    end

    def session_key
      # Use config.id to store session per client instance
      Thread.current[:qbittorrent_sessions] ||= {}
      Thread.current[:qbittorrent_sessions][config.id] ||= {}
    end

    def session_valid?
      session_key[:sid].present?
    end

    def clear_session!
      session_key[:sid] = nil
    end

    def username
      config.username
    end

    def password
      config.password
    end

    def connection
      Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Cookie"] = "SID=#{session_key[:sid]}" if session_valid?
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def handle_response(response)
      case response.status
      when 200
        yield response.body
      when 401, 403
        clear_session!
        raise Base::AuthenticationError, "qBittorrent session expired"
      else
        raise Base::Error, "qBittorrent API error: #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent: #{e.message}"
    end

    def parse_torrent(data)
      # Prefer content_path (specific torrent directory) over save_path (category directory)
      # Fall back to save_path + name for older qBittorrent versions or when content_path is empty
      download_path = if data["content_path"].present?
        data["content_path"]
      elsif data["save_path"].present? && data["name"].present?
        File.join(data["save_path"], data["name"])
      else
        data["save_path"]
      end

      Base::TorrentInfo.new(
        hash: data["hash"],
        name: data["name"],
        progress: (data["progress"] * 100).round,
        state: normalize_state(data["state"]),
        size_bytes: data["size"],
        download_path: download_path
      )
    end

    def normalize_state(state)
      case state
      when "downloading", "forcedDL", "metaDL", "queuedDL", "allocating", "checkingDL"
        :downloading
      when "stalledDL", "pausedDL"
        :paused
      when "uploading", "forcedUP", "stalledUP", "queuedUP", "pausedUP", "checkingUP"
        :completed
      when "error", "missingFiles"
        :failed
      else
        :queued
      end
    end
  end
end
