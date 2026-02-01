# frozen_string_literal: true

module DownloadClients
  # NZBGet JSON-RPC API client for usenet downloads
  # https://nzbget.net/api
  class Nzbget < Base
    # Add an NZB by URL (method named add_torrent for interface compatibility with Base)
    def add_torrent(url, options = {})
      Rails.logger.info "[Nzbget] Adding URL to queue (#{url.to_s.length} chars)"

      # appendurl params: URL, NZBFilename, Category, Priority, AddToTop, AddPaused, DupeKey, DupeScore, DupeMode
      result = rpc_call("appendurl", [
        "",                               # Filename
        url,                              # URL
        config.category.presence || "",   # Category
        0,                                # Priority
        false,                            # AddToTop
        false,                            # AddPaused
        "",                               # DupeKey
        0,                                # DupeScore
        "SCORE",                          # DupeMode
        false,                            # AutoCategory
        [],                               # PPParameters
      ])

      if result && result > 0
        Rails.logger.info "[Nzbget] Added NZB with ID: #{result}"
        { "nzo_ids" => [ result.to_s ] }
      else
        Rails.logger.error "[Nzbget] Failed to add NZB, result: #{result.inspect}"
        false
      end
    rescue Faraday::Error => e
      Rails.logger.error "[Nzbget] Connection error: #{e.message}"
      raise Base::ConnectionError, "Failed to connect to NZBGet: #{e.message}"
    end

    # Get info for a specific download by ID
    def torrent_info(nzbget_id)
      # Check queue first, then history
      queue_item = find_in_queue(nzbget_id)
      return queue_item if queue_item

      find_in_history(nzbget_id)
    end

    # List all downloads (queue + recent history)
    def list_torrents(filter = {})
      queue = list_queue
      history = list_history(limit: filter[:limit] || 50)
      queue + history
    end

    # Test connection to NZBGet
    def test_connection
      result = rpc_call("version")
      if result.is_a?(String) && result.present?
        Rails.logger.info "[Nzbget] Connection test passed - version: #{result}"
        true
      else
        Rails.logger.error "[Nzbget] Connection test failed - unexpected response: #{result.inspect}"
        false
      end
    rescue Base::Error, Faraday::Error => e
      Rails.logger.error "[Nzbget] Connection test failed: #{e.message}"
      false
    end

    # Remove a download by ID
    # delete_files: if true, also delete downloaded files
    def remove_torrent(nzbget_id, delete_files: false)
      id = nzbget_id.to_i

      # Try to delete from queue first using editqueue
      # EditQueue(Command, Offset, EditText, IDs)
      # GroupDelete removes the group and its files
      result = rpc_call("editqueue", [ "GroupDelete", 0, "", [ id ] ])

      if result == true
        Rails.logger.info "[Nzbget] Removed download #{nzbget_id} from queue"
        return true
      end

      # If not in queue, try history
      # HistoryDelete removes from history but keeps files
      # HistoryFinalDelete removes from history and deletes files
      history_command = delete_files ? "HistoryFinalDelete" : "HistoryDelete"
      result = rpc_call("editqueue", [ history_command, 0, "", [ id ] ])

      if result == true
        Rails.logger.info "[Nzbget] Removed download #{nzbget_id} from history (delete_files=#{delete_files})"
        true
      else
        Rails.logger.error "[Nzbget] Failed to remove download #{nzbget_id}"
        false
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to NZBGet: #{e.message}"
    end

    private

    def rpc_call(method, params = [])
      response = connection.post do |req|
        req.url "/jsonrpc"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          method: method,
          params: params
        }.to_json
      end

      handle_response(response)
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :authorization, :basic, config.username, config.password
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def handle_response(response)
      case response.status
      when 200
        body = response.body
        if body.is_a?(Hash)
          if body["error"]
            Rails.logger.error "[Nzbget] API returned error: #{body['error']}"
            raise Base::Error, "NZBGet error: #{body['error']}"
          end
          body["result"]
        else
          Rails.logger.error "[Nzbget] Unexpected response format: #{body.inspect.truncate(200)}"
          raise Base::Error, "NZBGet returned unexpected response format"
        end
      when 401, 403
        Rails.logger.error "[Nzbget] Authentication failed (status #{response.status})"
        raise Base::AuthenticationError, "NZBGet authentication failed"
      else
        Rails.logger.error "[Nzbget] API error (status #{response.status}): #{response.body.inspect.truncate(200)}"
        raise Base::Error, "NZBGet API error: #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      Rails.logger.error "[Nzbget] Connection error: #{e.message}"
      raise Base::ConnectionError, "Failed to connect to NZBGet: #{e.message}"
    end

    def list_queue
      result = rpc_call("listgroups", [ 0 ])  # 0 = return all fields
      return [] unless result.is_a?(Array)

      result.map { |item| parse_queue_item(item) }
    end

    def list_history(limit: 50)
      # history(Hidden) - Hidden=false to get normal history
      result = rpc_call("history", [ false ])
      return [] unless result.is_a?(Array)

      result
        .sort_by { it["HistoryTime"] }
        .take(limit)
        .map { |item| parse_history_item(item) }
    end

    def find_in_queue(nzbget_id)
      id = nzbget_id.to_i
      list_queue.find { |item| item.hash == nzbget_id.to_s }
    rescue Base::Error
      nil
    end

    def find_in_history(nzbget_id)
      list_history.first { |item| item.hash == nzbget_id.to_s }
    rescue Base::Error
      nil
    end

    def parse_queue_item(data)
      Base::TorrentInfo.new(
        hash: data["NZBID"].to_s,
        name: data["NZBName"],
        progress: calculate_progress(data),
        state: normalize_queue_state(data["Status"]),
        size_bytes: data["FileSizeMB"].to_f * 1024 * 1024,
        download_path: data["DestDir"].presence || ""
      )
    end

    def parse_history_item(data)
      # Rails.logger.error "#{data.inspect}"
      # Rails.logger.error "@" * 80

      Base::TorrentInfo.new(
        hash: data["NZBID"].to_s,
        name: data["Name"],
        progress: 100,
        state: normalize_history_state(data["Status"]),
        size_bytes: data["FileSizeMB"].to_f * 1024 * 1024,
        download_path: data["DestDir"].presence || "",
      )
    end

    def calculate_progress(data)
      total = data["FileSizeMB"].to_f
      remaining = data["RemainingSizeMB"].to_f
      return 0 if total <= 0

      progress = ((total - remaining) / total * 100).to_i
      progress.clamp(0, 100)
    end

    def normalize_queue_state(status)
      case status&.upcase
      when "DOWNLOADING"
        :downloading
      when "PAUSED", "PAUSING"
        :paused
      when "QUEUED", "FETCHING", "LOADING_PARS", "VERIFYING_SOURCES",
           "REPAIRING", "VERIFYING_REPAIRED", "RENAMING", "UNPACKING",
           "MOVING", "EXECUTING_SCRIPT", "PP_QUEUED", "POST-PROCESSING"
        :queued
      else
        :queued
      end
    end

    def normalize_history_state(status)
      case status.to_s.strip.upcase
      when "SUCCESS/UNPACK"
        :completed
      when "FAILURE", "DELETED"
        :failed
      else
        :queued
      end
    end
  end
end
