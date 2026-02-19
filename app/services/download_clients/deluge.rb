# frozen_string_literal: true

module DownloadClients
  # Deluge Web API client
  class Deluge < Base
    AUTH_ERROR_PATTERNS = [
      /not logged in/i,
      /authentication/i,
      /not authorized/i,
      /not permitted/i
    ].freeze

    TORRENT_FIELDS = [
      "name",
      "hash",
      "state",
      "progress",
      "total_size",
      "download_location",
      "save_path"
    ].freeze

    def add_torrent(url, options = {})
      ensure_authenticated!

      params = build_add_params(options)
      existing_ids = torrent_ids

      # Deluge typically accepts torrent URLs and magnet links via add_torrent_url
      # Some deployments return no direct ID, so we keep a session-state fallback.
      result = rpc_call("core.add_torrent_url", [url, params])

      return result if result.is_a?(String) && result.present?

      new_ids = torrent_ids - existing_ids
      new_ids.first
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Deluge: #{e.message}"
    end

    def torrent_info(hash)
      ensure_authenticated!

      torrent = torrent_status(hash.to_s)
      return nil unless torrent

      parse_torrent(torrent[0], torrent[1])
    end

    def list_torrents(filter = {})
      ensure_authenticated!

      torrents = torrent_statuses(filter)
      torrents.map { |torrent_id, data| parse_torrent(torrent_id, data) }
    end

    def test_connection
      ensure_authenticated!

      torrent_ids
      true
    rescue Base::Error, Base::AuthenticationError, Faraday::Error => e
      Rails.logger.warn "[Deluge] Connection test failed: #{e.message}"
      false
    end

    def remove_torrent(hash, delete_files: false)
      ensure_authenticated!

      # Deluge accepts arrays of torrent IDs
      result = rpc_call("core.remove_torrents", [Array(hash), delete_files])
      !result.nil?

    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Deluge: #{e.message}"
    end

    private

    def ensure_authenticated!
      authenticate! unless session_valid?
    end

    def authenticate!
      response = connection.post("/json") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = {
          method: "auth.login",
          params: [config.password.to_s],
          id: 1
        }.to_json
      end

      body = parse_body(response)
      unless body["result"] == true
        raise Base::AuthenticationError, "Deluge authentication failed"
      end

      set_session!(response)
      true
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Deluge: #{e.message}"
    end

    def rpc_call(method, params = [])
      response = connection.post("/json") do |req|
        req.headers["Content-Type"] = "application/json"
        req.headers["Cookie"] = session_cookie if session_valid?
        req.body = {
          method: method,
          params: params,
          id: 1
        }.to_json
      end

      body = parse_body(response)
      handle_error_response(method, body)
      body["result"]
    end

    def parse_body(response)
      if response.status == 401 || response.status == 403
        clear_session!
        raise Base::AuthenticationError, "Deluge authentication failed: #{response.status}"
      end

      unless response.status == 200
        raise Base::Error, "Deluge API error: #{response.status}"
      end

      body = response.body
      unless body.is_a?(Hash)
        raise Base::Error, "Deluge API returned unexpected response format"
      end

      body
    end

    def handle_error_response(method, body)
      error = body["error"]
      return if error.nil?

      message = extract_error_message(error)
      if AUTH_ERROR_PATTERNS.any? { |pattern| pattern.match?(message) }
        clear_session!
        raise Base::AuthenticationError, "Deluge authentication failed: #{message}"
      end

      raise Base::Error, "Deluge API error in #{method}: #{message}"
    end

    def set_session!(response)
      set_cookie = response.headers["set-cookie"] || response.headers["Set-Cookie"]
      return unless set_cookie.present?

      session[:cookie] = set_cookie.to_s.split(";").first
    end

    def torrent_ids
      rpc_call("core.get_session_state") || []
    end

    def torrent_statuses(filter = {})
      normalized_filter = filter.to_h.with_indifferent_access
      rpc_call("core.get_torrents_status", [normalized_filter, TORRENT_FIELDS]) || {}
    rescue Base::Error
      {}
    end

    def torrent_status(hash)
      torrent_statuses({ id: hash }).first
    end

    def parse_torrent(id, data)
      progress = normalize_progress(data["progress"])
      Base::TorrentInfo.new(
        hash: id,
        name: data["name"],
        progress: progress,
        state: normalize_state(data["state"].to_s),
        size_bytes: data["total_size"].to_f,
        download_path: data["download_location"].presence || data["save_path"].to_s
      )
    end

    def normalize_progress(progress)
      return 0 if progress.blank?

      normalized = progress.to_f
      normalized *= 100 if normalized <= 1.0
      normalized.round
    end

    def normalize_state(state)
      case state
      when "Downloading", "Checking", "CheckingResumeData", "Queued", "Moving", "Allocating", "Creating"
        :downloading
      when "Seeding"
        :completed
      when "Error", "ErrorPause"
        :failed
      when "Paused", "PausedDownload", "PausedUpload"
        :paused
      when "Stopped"
        :paused
      else
        :queued
      end
    end

    def build_add_params(options)
      params = {}
      params["download_location"] = options[:save_path] if options[:save_path].present?
      params["label"] = config.category if config.category.present?
      params["add_paused"] = options[:paused] if options.key?(:paused)
      params
    end

    def connection
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def session
      Thread.current[:deluge_sessions] ||= {}
      Thread.current[:deluge_sessions][config.id] ||= {}
    end

    def session_valid?
      session[:cookie].present?
    end

    def clear_session!
      session.delete(:cookie)
    end

    def extract_error_message(error)
      return error["message"].to_s if error.is_a?(Hash)

      error.to_s
    end

    def session_cookie
      session[:cookie]
    end
  end
end
