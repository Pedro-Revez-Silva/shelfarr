# frozen_string_literal: true

require "base64"
require "bencode"

module DownloadClients
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

    LABEL_ASSIGN_MAX_ATTEMPTS = 3
    LABEL_ASSIGN_RETRY_WAIT = 0.25
    LABEL_PLUGIN_READY_MAX_ATTEMPTS = 5
    LABEL_PLUGIN_READY_RETRY_WAIT = 0.2
    DUPLICATE_TORRENT_PATTERN = /already in session|already being added/i
    GATEWAY_TIMEOUT_STATUS = 504
    UNDELIVERED_REQUEST_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EADDRNOTAVAIL,
      SocketError,
      Net::OpenTimeout
    ].freeze
    REMOVE_UNTRACKED_TORRENT_GUIDANCE = "If Deluge shows this torrent paused, Shelfarr is not tracking it: remove it in Deluge, then retry."

    class UnconfirmedReplyError < Base::ConnectionError; end
    TRANSIENT_LABEL_ERROR_PATTERNS = [
      /unknown torrent/i,
      /timeout/i,
      /timed out/i
    ].freeze

    def add_torrent(url, options = {})
      ensure_authenticated!
      ensure_configured_label!

      start_after_staging = !add_paused?(options)
      prepared = prepare_torrent_submission(url, validate_source_url: options[:validate_source_url])
      result = submit_new_torrent(prepared, build_add_params(options))
      torrent_id = result if result.is_a?(String) && result.present?

      if torrent_id.blank?
        if configured_label.present?
          raise Base::Error, "Deluge did not return a torrent id after add; cannot assign label"
        end

        return nil
      end

      stage_added_torrent!(torrent_id, start: start_after_staging)
      torrent_id
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
      ensure_configured_label!
      true
    rescue Base::Error, Base::AuthenticationError, Faraday::Error => e
      Rails.logger.warn "[Deluge] Connection test failed: #{e.message}"
      RemoteResult::Failed.new(e)
    end

    def remove_torrent(hash, delete_files: false)
      ensure_authenticated!

      # Deluge accepts arrays of torrent IDs
      result = rpc_call("core.remove_torrents", [Array(hash), delete_files])
      result == true || (result.is_a?(Array) && result.empty?)

    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to Deluge: #{e.message}"
    end

    private

    def ensure_authenticated!
      authenticate! unless session_valid?
    end

    def authenticate!
      response = connection.post("json") do |req|
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
      response = connection.post("json") do |req|
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

      if response.status == GATEWAY_TIMEOUT_STATUS
        raise UnconfirmedReplyError, "Deluge API error: #{response.status}"
      end

      unless response.status == 200
        raise_for_http_status!(response.status, "Deluge API error: #{response.status}")
      end

      body = response.body
      unless body.is_a?(Hash)
        raise Base::ConnectionError, "Deluge API returned unexpected response format"
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
      statuses = rpc_call("core.get_torrents_status", [ normalized_filter, TORRENT_FIELDS ]) || {}
      raise Base::ConnectionError, "Deluge returned unreadable torrent statuses" unless statuses.is_a?(Hash)

      statuses
    end

    def torrent_status(hash)
      torrent_statuses({ id: hash }).first
    end

    def parse_torrent(id, data)
      path = torrent_download_path(data)
      Base::TorrentInfo.new(
        hash: id,
        name: data["name"],
        progress: normalize_progress(data["progress"]),
        state: download_state(
          unit: :percent,
          progress: data["progress"],
          state: { deluge: data["state"] },
          path: path
        ),
        size_bytes: data["total_size"].to_f,
        download_path: path
      )
    end

    def torrent_download_path(data)
      location = data["download_location"].presence || data["save_path"].presence
      name = data["name"].presence
      return location.to_s if location.blank? || name.blank?

      File.join(location, name)
    end

    def normalize_progress(progress)
      return 0 if progress.blank?

      # Deluge reports percentages from 0 to 100, including values below 1%.
      progress.to_f.round
    end

    def add_paused?(options)
      return options[:paused] == true if options.key?(:paused)

      rpc_call("core.get_config_value", [ "add_paused" ]) == true
    rescue Base::ConnectionError, Base::AuthenticationError
      raise
    rescue Base::Error => error
      raise Base::ConfigurationError, "Deluge could not report its add_paused setting: #{error.message}"
    end

    def submit_new_torrent(prepared, params)
      submit_torrent(prepared, params)
    rescue Faraday::Error => error
      raise if undelivered_request?(error)

      raise_unconfirmed_add!(error)
    rescue UnconfirmedReplyError => error
      raise_unconfirmed_add!(error)
    rescue Base::ConnectionError, Base::AuthenticationError
      raise
    rescue Base::Error => error
      raise unless DUPLICATE_TORRENT_PATTERN.match?(error.message)

      raise Base::ConfigurationError,
        "Deluge already has this torrent, so Shelfarr did not adopt or change it. " \
        "Deluge may have merged this release's trackers into it. #{REMOVE_UNTRACKED_TORRENT_GUIDANCE} (#{error.message})"
    end

    def undelivered_request?(error)
      UNDELIVERED_REQUEST_ERRORS.any? { |error_class| error.wrapped_exception.is_a?(error_class) }
    end

    def raise_unconfirmed_add!(error)
      raise Base::ConfigurationError,
        "Deluge did not confirm whether it added this torrent. #{REMOVE_UNTRACKED_TORRENT_GUIDANCE} (#{error.message})"
    end

    def stage_added_torrent!(torrent_id, start:)
      assign_configured_label!(torrent_id)
      rpc_call("core.set_torrent_options", [ [ torrent_id ], { "remove_at_ratio" => false } ])
      rpc_call("core.resume_torrent", [ [ torrent_id ] ]) if start
    rescue Base::Error, Faraday::Error => error
      discard_staged_torrent(torrent_id)
      raise Base::ConfigurationError, "Deluge could not prepare the added torrent: #{error.message}"
    end

    def build_add_params(options)
      params = {}
      params["download_location"] = options[:save_path] if options[:save_path].present?
      params["add_paused"] = true
      params["remove_at_ratio"] = false
      params
    end

    def ensure_configured_label!
      label = configured_label
      return unless label

      ensure_label_plugin_enabled!
      labels = fetch_labels_with_retry!
      add_label!(label) unless labels.include?(label)
    end

    def ensure_label_plugin_enabled!
      enabled_plugins = Array(rpc_call("core.get_enabled_plugins"))
      return if enabled_plugins.include?("Label")

      available_plugins = Array(rpc_call("core.get_available_plugins"))
      unless available_plugins.include?("Label")
        raise Base::NotConfiguredError, "Deluge Label plugin is not available"
      end

      enabled = rpc_call("core.enable_plugin", [ "Label" ])
      raise Base::NotConfiguredError, "Deluge Label plugin could not be enabled" unless enabled
    end

    def fetch_labels_with_retry!
      last_error = nil

      LABEL_PLUGIN_READY_MAX_ATTEMPTS.times do |attempt|
        sleep LABEL_PLUGIN_READY_RETRY_WAIT if attempt > 0

        begin
          return Array(rpc_call("label.get_labels"))
        rescue Base::Error => e
          last_error = e
          next if plugin_method_not_ready?(e)

          raise
        end
      end

      raise last_error if last_error

      raise Base::NotConfiguredError, "Deluge Label plugin methods are not available yet"
    end

    def plugin_method_not_ready?(error)
      error.message.match?(/unknown method|method not found|not available|has no attribute/i)
    end

    def add_label!(label)
      rpc_call("label.add", [ label ])
    rescue Base::Error
      raise unless fetch_labels_with_retry!.include?(label)
    end

    def assign_configured_label!(torrent_id)
      label = configured_label
      return if label.blank? || torrent_id.blank?

      set_torrent_label_with_retry!(torrent_id, label)
    rescue Base::Error, Faraday::Error => label_error
      if stale_label_configuration_error?(label_error)
        begin
          ensure_configured_label!
          return set_torrent_label_with_retry!(torrent_id, label)
        rescue Base::Error, Faraday::Error => retry_error
          label_error = retry_error
        end
      end

      raise label_error
    end

    def stale_label_configuration_error?(error)
      error.message.match?(/unknown label|unknown method|method not found|not available|has no attribute/i)
    end

    def set_torrent_label_with_retry!(torrent_id, label)
      last_error = nil

      LABEL_ASSIGN_MAX_ATTEMPTS.times do |attempt|
        sleep LABEL_ASSIGN_RETRY_WAIT if attempt > 0

        begin
          return rpc_call("label.set_torrent", [ torrent_id, label ])
        rescue Base::Error, Faraday::Error => e
          last_error = e
          next if transient_label_error?(e)

          raise
        end
      end

      raise last_error
    end

    def transient_label_error?(error)
      return true if error.is_a?(Faraday::Error)

      TRANSIENT_LABEL_ERROR_PATTERNS.any? { |pattern| pattern.match?(error.message) }
    end

    def discard_staged_torrent(torrent_id)
      return if remove_torrent(torrent_id, delete_files: false)

      Rails.logger.error "[Deluge] Deluge did not remove staged torrent #{torrent_id}; it stays paused"
    rescue Base::Error => cleanup_error
      Rails.logger.error "[Deluge] Failed to remove staged torrent #{torrent_id}; it stays paused: #{cleanup_error.message}"
    end

    def configured_label
      config.category.to_s.strip.downcase.presence
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

    def prepare_torrent_submission(url, validate_source_url: false)
      return { url: url } if url.blank?
      if url.start_with?("magnet:")
        return { url: validate_source_url ? sanitize_untrusted_magnet!(url) : url }
      end

      source = if validate_source_url
        resolve_guarded_torrent_source(url)
      else
        resolve_torrent_source(url)
      end
      if RemoteResult.failed?(source) || source.blank?
        raise Base::Error, "Could not safely fetch torrent source" if validate_source_url

        return { url: url }
      end

      resolved_url = source[:url].presence || url
      return { url: resolved_url } if resolved_url.start_with?("magnet:")

      torrent_data = source[:torrent_data]
      unless valid_torrent_data?(torrent_data) == true
        raise Base::Error, "Torrent source did not return a valid torrent file" if validate_source_url

        return { url: resolved_url }
      end

      {
        url: resolved_url,
        filename: torrent_filename(resolved_url),
        torrent_data: torrent_data
      }
    end

    def submit_torrent(prepared, params)
      url = prepared[:url].to_s

      if prepared[:torrent_data].present?
        rpc_call(
          "core.add_torrent_file",
          [
            prepared[:filename],
            Base64.strict_encode64(prepared[:torrent_data]),
            params
          ]
        )
      elsif url.start_with?("magnet:")
        rpc_call("core.add_torrent_magnet", [ url, params ])
      else
        rpc_call("core.add_torrent_url", [ url, params ])
      end
    end

    def resolve_torrent_source(raw_url)
      normalized_url = normalized_torrent_url(raw_url)
      return nil if RemoteResult.failed?(normalized_url) || normalized_url.blank?

      current_url = normalized_url
      max_redirects = 10

      max_redirects.times do
        response = torrent_download_connection.get do |req|
          req.url current_url
        end

        location = response.headers["location"]
        if response.status.between?(300, 399) && location.present?
          redirected_url = absolutize_redirect_url(current_url, location)
          return { url: current_url } if RemoteResult.failed?(redirected_url) || redirected_url.blank?
          return { url: redirected_url } if redirected_url.start_with?("magnet:")

          current_url = redirected_url
          next
        end

        magnet = extract_magnet_from_body(response.body.to_s)
        return { url: magnet } if magnet.present?
        return { url: current_url, torrent_data: response.body } if response.success? && response.body.present?

        return { url: current_url }
      end

      Rails.logger.warn "[Deluge] Too many redirects while fetching torrent: #{normalized_url.truncate(100)}"
      { url: current_url }
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Deluge] Invalid torrent URL: #{e.message}"
      RemoteResult::Failed.new(e)
    rescue Faraday::Error => e
      Rails.logger.warn "[Deluge] Failed to download torrent file for direct upload: #{e.message}"
      RemoteResult::Failed.new(e)
    end

    def valid_torrent_data?(torrent_data)
      return false if torrent_data.blank?

      parsed = BEncode.load(torrent_data.dup)
      parsed.is_a?(Hash) && parsed["info"].is_a?(Hash)
    rescue BEncode::DecodeError => error
      RemoteResult::Failed.new(error)
    end

    def normalized_torrent_url(raw_url)
      uri = URI.parse(raw_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.to_s
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[Deluge] Invalid torrent URL: #{e.message}"
      RemoteResult::Failed.new(e)
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
    rescue URI::InvalidURIError => error
      RemoteResult::Failed.new(error)
    end

    def extract_magnet_from_body(body)
      body.match(/magnet:\?[^\s"'<>]+/i)&.to_s
    end

    def torrent_filename(url)
      path = URI.parse(url).path
      filename = File.basename(path.to_s)
      filename = "shelfarr.torrent" if filename.blank? || filename == "/"
      filename = "#{filename}.torrent" unless filename.end_with?(".torrent")
      filename
    rescue URI::InvalidURIError
      "shelfarr.torrent"
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
