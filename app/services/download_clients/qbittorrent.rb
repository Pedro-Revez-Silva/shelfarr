# frozen_string_literal: true

require "bencode"
require "digest/sha1"
require "faraday/multipart"

module DownloadClients
  # qBittorrent WebUI API client
  # https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)
  class Qbittorrent < Base
    # Add a torrent by URL or magnet link
    # Returns the torrent hash on success, nil on failure
    def add_torrent(url, options = {})
      ensure_authenticated!

      # Pre-compute hash before adding to avoid race conditions with concurrent downloads
      # Priority: magnet hash > torrent file hash > polling fallback
      precomputed = precompute_torrent_hash(url)
      precomputed_hash = precomputed&.dig(:hash)
      torrent_data = precomputed&.dig(:torrent_data)

      # Only capture existing hashes if we couldn't pre-compute the hash
      # This is the fallback for edge cases where hash extraction fails
      category = config.category.presence
      existing_hashes = precomputed_hash.present? ? nil : fetch_torrent_hashes(category: category)

      if torrent_data
        # Upload torrent file directly — essential for seedbox setups where
        # qBittorrent can't reach the indexer URL (e.g., local Prowlarr)
        Rails.logger.info "[Qbittorrent] Uploading torrent file directly to #{config.name}"
        response = upload_torrent_file(torrent_data, options)
      else
        # Magnet links or failed torrent downloads: pass URL to qBittorrent
        params = { urls: url }
        params[:category] = config.category if config.category.present?
        params[:savepath] = options[:save_path] if options[:save_path].present?
        params[:paused] = options[:paused] ? "true" : "false" if options.key?(:paused)
        response = connection.post("api/v2/torrents/add", params)
      end

      case response.status
      when 200
        # qBittorrent returns "Ok." on success or empty body
        return nil unless response.body == "Ok." || response.body.blank?

        # Return pre-computed hash if available (eliminates race condition)
        if precomputed_hash.present?
          Rails.logger.info "[Qbittorrent] Using pre-computed hash: #{precomputed_hash}"

          # Verify torrent was actually added (qBittorrent returns "Ok." even when it fails silently)
          if verify_torrent_added(precomputed_hash)
            return precomputed_hash
          else
            Rails.logger.error "[Qbittorrent] Torrent #{precomputed_hash} not found after adding to #{config.name} - " \
                               "qBittorrent may have rejected it (check disk permissions, save path, or duplicate torrent)"
            return nil
          end
        end

        # Fallback: detect the newly added torrent by comparing hashes
        # This path is only taken if hash extraction failed
        Rails.logger.warn "[Qbittorrent] Falling back to polling for hash detection (race condition possible)"
        find_newly_added_torrent_hash(existing_hashes, category: category)
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

      response = connection.get("api/v2/torrents/info", { hashes: hash })

      handle_response(response) do |data|
        return nil if data.blank?

        parse_torrent(data.first)
      end
    end

    # List all torrents
    def list_torrents(filter = {})
      ensure_authenticated!

      response = connection.get("api/v2/torrents/info", filter)

      handle_response(response) do |data|
        Array(data).map { |t| parse_torrent(t) }
      end
    end

    # Test connection - verifies both authentication AND API accessibility
    # This catches seedbox subpath issues where auth works but API endpoints return 404
    def test_connection
      ensure_authenticated!

      # Actually call an API endpoint to verify the full path works
      # (not just authentication which uses a different code path)
      url = "#{base_url}/api/v2/app/version"
      response = connection.get("api/v2/app/version")

      if response.status == 200
        Rails.logger.info "[Qbittorrent] Connection test passed - version: #{response.body}"
        ensure_category_exists!
        true
      else
        # Clear stale session so next attempt re-authenticates
        clear_session! if response.status == 401 || response.status == 403
        Rails.logger.error "[Qbittorrent] Connection test failed: GET #{url} returned #{response.status} (#{response.body.to_s.truncate(200)})"
        false
      end
    rescue AuthenticationError => e
      Rails.logger.error "[Qbittorrent] Authentication failed for #{config.name} at #{base_url}: #{e.message}"
      false
    rescue ConnectionError => e
      Rails.logger.error "[Qbittorrent] Connection failed for #{config.name} at #{base_url}: #{e.message}"
      false
    rescue Error => e
      Rails.logger.error "[Qbittorrent] Unexpected error for #{config.name} at #{base_url}: #{e.message}"
      false
    end

    # Remove a torrent by hash
    # delete_files: if true, also delete downloaded files from disk
    def remove_torrent(hash, delete_files: false)
      ensure_authenticated!

      response = connection.post("api/v2/torrents/delete", {
        hashes: hash,
        deleteFiles: delete_files.to_s
      })

      case response.status
      when 200
        Rails.logger.info "[Qbittorrent] Removed torrent #{hash} (delete_files: #{delete_files})"
        true
      when 401, 403
        clear_session!
        raise Base::AuthenticationError, "qBittorrent session expired"
      else
        Rails.logger.error "[Qbittorrent] Failed to remove torrent: #{response.status}"
        false
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent: #{e.message}"
    end

    # Auto-create the configured category in qBittorrent (idempotent)
    def ensure_category_exists!
      return unless config.category.present?

      response = connection.post("api/v2/torrents/createCategory", { category: config.category })
      case response.status
      when 200
        Rails.logger.info "[Qbittorrent] Category '#{config.category}' created in #{config.name}"
      when 409
        # Already exists — expected
      else
        Rails.logger.warn "[Qbittorrent] Failed to create category '#{config.category}': HTTP #{response.status}"
      end
    rescue => e
      Rails.logger.warn "[Qbittorrent] Failed to ensure category (non-fatal): #{e.message}"
    end

    # Fetch qBittorrent's save path and category info for diagnostics
    def connection_diagnostics
      ensure_authenticated!

      prefs = {}
      cats = {}

      prefs_response = connection.get("api/v2/app/preferences")
      prefs = prefs_response.body if prefs_response.status == 200

      cats_response = connection.get("api/v2/torrents/categories")
      cats = cats_response.body if cats_response.status == 200

      {
        save_path: prefs["save_path"],
        categories: cats,
        category_save_path: config.category.present? ? cats.dig(config.category, "savePath") : nil
      }
    rescue => e
      Rails.logger.warn "[Qbittorrent] Failed to fetch diagnostics: #{e.message}"
      nil
    end

    private

    # Verify that a torrent was actually added to qBittorrent
    # qBittorrent may return "Ok." but fail to add the torrent due to:
    # - Disk permissions issues
    # - Invalid save path
    # - Duplicate torrent (if configured to reject)
    # - Torrent file rejection
    def verify_torrent_added(hash, max_attempts: 3, wait_time: 1)
      max_attempts.times do |attempt|
        # Only sleep on retry attempts to avoid unnecessary delay if torrent is immediately available
        sleep wait_time if attempt > 0

        info = torrent_info(hash)
        if info.present?
          Rails.logger.info "[Qbittorrent] Verified torrent #{hash} exists in client (attempt #{attempt + 1})"
          return true
        end
        Rails.logger.debug "[Qbittorrent] Torrent #{hash} not found yet (attempt #{attempt + 1}/#{max_attempts})"
      end
      false
    end

    # Pre-compute torrent hash from URL to avoid race conditions
    # Returns { hash: String, torrent_data: String? } on success, nil otherwise
    # torrent_data is only present for torrent file URLs (not magnets)
    def precompute_torrent_hash(url)
      if url.start_with?("magnet:")
        hash = extract_hash_from_magnet(url)
        hash ? { hash: hash } : nil
      elsif torrent_file_url?(url)
        download_and_extract_hash(url)
      end
    end

    def extract_hash_from_magnet(url)
      match = url.match(/btih:([a-fA-F0-9]+)/i)
      match[1]&.downcase if match
    end

    # Check if URL points to a .torrent file
    def torrent_file_url?(url)
      return false if url.blank?

      # Check file extension
      return true if url.match?(/\.torrent(\?|$)/i)

      # Many private trackers use URLs like /download.php?id=123 that return torrent files
      # We'll attempt to download and parse - if it fails, we fall back to polling
      true
    end

    # Download .torrent file and extract the info hash
    # The info hash is the SHA1 of the bencoded "info" dictionary
    # Returns { hash: String, torrent_data: String } on success, nil on failure
    # torrent_data is preserved so it can be uploaded directly to qBittorrent
    # (essential for seedbox setups where qBittorrent can't reach the indexer URL)
    def download_and_extract_hash(url)
      normalized_url = normalized_torrent_url(url)
      return nil unless normalized_url

      Rails.logger.info "[Qbittorrent] Downloading torrent file to extract hash: #{normalized_url.truncate(100)}"
      response = torrent_download_connection.get(normalized_url)

      unless response.success?
        Rails.logger.warn "[Qbittorrent] Failed to download torrent file: HTTP #{response.status}"
        return nil
      end

      torrent_data = response.body
      return nil if torrent_data.blank?

      # Parse the torrent file (bencoded format)
      parsed = BEncode.load(torrent_data)
      return nil unless parsed.is_a?(Hash) && parsed["info"].is_a?(Hash)

      # The info hash is the SHA1 of the bencoded "info" dictionary
      info_bencoded = parsed["info"].bencode
      hash = Digest::SHA1.hexdigest(info_bencoded).downcase

      Rails.logger.info "[Qbittorrent] Extracted hash from torrent file: #{hash}"
      { hash: hash, torrent_data: torrent_data }
    rescue BEncode::DecodeError => e
      Rails.logger.warn "[Qbittorrent] Failed to parse torrent file (not valid bencode): #{e.message}"
      nil
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Qbittorrent] Invalid torrent URL for hash extraction: #{e.message}"
      nil
    rescue Faraday::Error => e
      Rails.logger.warn "[Qbittorrent] Failed to download torrent file: #{e.message}"
      nil
    rescue => e
      Rails.logger.warn "[Qbittorrent] Unexpected error extracting hash: #{e.class} - #{e.message}"
      nil
    end

    def normalized_torrent_url(raw_url)
      return nil if raw_url.blank?

      uri = URI.parse(raw_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.to_s
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Qbittorrent] Invalid torrent URL for hash extraction: #{e.message}"
      nil
    end

    # Separate connection for downloading torrent files (different from qBittorrent API)
    def torrent_download_connection
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 30
        f.options.open_timeout = 10
        # Follow redirects (common for torrent download URLs)
        f.response :follow_redirects, limit: 5
        # Accept any content type (torrent files have various content types)
        f.headers["Accept"] = "*/*"
        # Some trackers require a user agent
        f.headers["User-Agent"] = "Shelfarr/1.0"
      end
    end

    # Upload a .torrent file directly to qBittorrent via multipart form upload
    # This is used instead of passing URLs so qBittorrent doesn't need to reach the indexer
    # (critical for seedbox setups where qBittorrent is on a different network)
    def upload_torrent_file(torrent_data, options = {})
      upload_conn = Faraday.new(url: base_url) do |f|
        f.request :multipart
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        f.headers["Cookie"] = "SID=#{session_key[:sid]}" if session_valid?
        f.headers["Referer"] = base_url
        f.headers["Origin"] = base_url
        f.options.timeout = 30
        f.options.open_timeout = 10
      end

      payload = {
        torrents: Faraday::Multipart::FilePart.new(
          StringIO.new(torrent_data),
          "application/x-bittorrent",
          "torrent.torrent"
        )
      }
      payload[:category] = config.category if config.category.present?
      payload[:savepath] = options[:save_path] if options[:save_path].present?
      payload[:paused] = options[:paused] ? "true" : "false" if options.key?(:paused)

      upload_conn.post("api/v2/torrents/add", payload)
    end

    # Fetch torrent hashes as a Set, optionally filtered by category
    def fetch_torrent_hashes(category: nil)
      params = category.present? ? { category: category } : {}
      response = connection.get("api/v2/torrents/info", params)
      return Set.new unless response.status == 200

      Set.new(Array(response.body).map { |t| t["hash"] })
    end

    # Poll for a newly added torrent by comparing against existing hashes
    # This is more reliable than querying "most recent" which can race with other downloads
    # Filters by category to reduce false positives from torrents added by other programs
    def find_newly_added_torrent_hash(existing_hashes, category: nil)
      max_wait_seconds = 30

      max_wait_seconds.times do |attempt|
        sleep 1

        current_hashes = fetch_torrent_hashes(category: category)
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
      login_url = "#{base_url}/api/v2/auth/login"
      Rails.logger.info "[Qbittorrent] Authenticating to #{config.name} at #{login_url} (username: #{username})"

      auth_response = Faraday.post(
        login_url,
        { username: username, password: password }
      ) do |req|
        req.headers["Referer"] = base_url
        req.headers["Origin"] = base_url
      end

      if auth_response.status == 200 && auth_response.body == "Ok."
        # Extract SID cookie from response
        cookie = auth_response.headers["set-cookie"]
        match = cookie&.match(/SID=([^;]+)/)
        if match
          session_key[:sid] = match[1]
          Rails.logger.info "[Qbittorrent] Authenticated successfully to #{config.name}"
        else
          raise Base::AuthenticationError, "No session cookie received from qBittorrent at #{login_url}"
        end
      elsif auth_response.status == 403
        raise Base::AuthenticationError,
          "qBittorrent rejected login at #{login_url} with 403 Forbidden — " \
          "ensure the URL is reachable and CSRF protection allows this host"
      else
        raise Base::AuthenticationError,
          "qBittorrent login failed at #{login_url}: HTTP #{auth_response.status} — #{auth_response.body}"
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent at #{login_url}: #{e.message}"
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
        f.headers["Referer"] = base_url
        f.headers["Origin"] = base_url
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
        Rails.logger.error "[Qbittorrent] Session expired or rejected (HTTP #{response.status}) for #{config.name} at #{base_url}"
        raise Base::AuthenticationError, "qBittorrent session expired (HTTP #{response.status}) at #{base_url}"
      else
        Rails.logger.error "[Qbittorrent] API error: HTTP #{response.status} from #{base_url} — #{response.body.to_s.truncate(200)}"
        raise Base::Error, "qBittorrent API error: #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise Base::ConnectionError, "Failed to connect to qBittorrent at #{base_url}: #{e.message}"
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
