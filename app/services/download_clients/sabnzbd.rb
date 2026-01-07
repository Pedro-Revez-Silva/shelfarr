# frozen_string_literal: true

module DownloadClients
  # SABnzbd API client for usenet downloads
  # https://sabnzbd.org/wiki/advanced/api
  class Sabnzbd < Base
    # Add an NZB by URL
    def add_torrent(url, options = {})
      Rails.logger.info "[Sabnzbd] Adding URL to queue (#{url.to_s.length} chars)"
      Rails.logger.debug "[Sabnzbd] Full URL being sent: #{url}"

      params = {
        mode: "addurl",
        name: url,
        apikey: api_key,
        output: "json"
      }
      params[:cat] = config.category if config.category.present?

      response = connection.get("/api", params)
      handle_response(response) do |data|
        Rails.logger.info "[Sabnzbd] API response: status=#{data['status']}, nzo_ids=#{data['nzo_ids']&.inspect}"
        # Return the response data so we can extract nzo_ids
        data["status"] == true ? data : false
      end
    rescue Faraday::Error => e
      Rails.logger.error "[Sabnzbd] Connection error: #{e.message}"
      raise Base::ConnectionError, "Failed to connect to SABnzbd: #{e.message}"
    end

    # Get info for a specific download by nzo_id
    def torrent_info(nzo_id)
      # Check queue first, then history
      queue_item = find_in_queue(nzo_id)
      return queue_item if queue_item

      find_in_history(nzo_id)
    end

    # List all downloads (queue + recent history)
    def list_torrents(filter = {})
      queue = list_queue
      history = list_history(limit: filter[:limit] || 50)
      queue + history
    end

    # Test connection to SABnzbd
    def test_connection
      response = connection.get("/api", { mode: "version", apikey: api_key, output: "json" })
      response.status == 200
    rescue Base::Error, Faraday::Error
      false
    end

    # Remove a download by nzo_id
    # delete_files: if true, also delete downloaded files
    def remove_torrent(nzo_id, delete_files: false)
      # Try to delete from queue first
      response = connection.get("/api", {
        mode: "queue",
        name: "delete",
        value: nzo_id,
        del_files: delete_files ? 1 : 0,
        apikey: api_key,
        output: "json"
      })

      if response.status == 200 && response.body["status"] == true
        Rails.logger.info "[Sabnzbd] Removed download #{nzo_id} from queue"
        return true
      end

      # If not in queue, try history
      response = connection.get("/api", {
        mode: "history",
        name: "delete",
        value: nzo_id,
        del_files: delete_files ? 1 : 0,
        apikey: api_key,
        output: "json"
      })

      if response.status == 200 && response.body["status"] == true
        Rails.logger.info "[Sabnzbd] Removed download #{nzo_id} from history"
        true
      else
        Rails.logger.error "[Sabnzbd] Failed to remove download #{nzo_id}"
        false
      end
    rescue Faraday::Error => e
      raise Base::ConnectionError, "Failed to connect to SABnzbd: #{e.message}"
    end

    private

    def api_key
      config.api_key
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
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
        # SABnzbd returns error in JSON body sometimes
        if body.is_a?(Hash) && body["error"]
          Rails.logger.error "[Sabnzbd] API returned error: #{body['error']}"
          raise Base::Error, "SABnzbd error: #{body['error']}"
        end
        yield body
      when 401, 403
        Rails.logger.error "[Sabnzbd] Authentication failed (status #{response.status})"
        raise Base::AuthenticationError, "SABnzbd authentication failed"
      else
        Rails.logger.error "[Sabnzbd] API error (status #{response.status}): #{response.body.inspect.truncate(200)}"
        raise Base::Error, "SABnzbd API error: #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      Rails.logger.error "[Sabnzbd] Connection error: #{e.message}"
      raise Base::ConnectionError, "Failed to connect to SABnzbd: #{e.message}"
    end

    def list_queue
      response = connection.get("/api", { mode: "queue", apikey: api_key, output: "json" })
      handle_response(response) do |data|
        slots = data.dig("queue", "slots") || []
        slots.map { |s| parse_queue_item(s) }
      end
    end

    def list_history(limit: 50)
      response = connection.get("/api", { mode: "history", limit: limit, apikey: api_key, output: "json" })
      handle_response(response) do |data|
        slots = data.dig("history", "slots") || []
        slots.map { |s| parse_history_item(s) }
      end
    end

    def find_in_queue(nzo_id)
      list_queue.find { |item| item.hash == nzo_id }
    rescue Base::Error
      nil
    end

    def find_in_history(nzo_id)
      list_history.find { |item| item.hash == nzo_id }
    rescue Base::Error
      nil
    end

    def parse_queue_item(data)
      Base::TorrentInfo.new(
        hash: data["nzo_id"],
        name: data["filename"],
        progress: data["percentage"].to_i,
        state: normalize_queue_state(data["status"]),
        size_bytes: (data["mb"].to_f * 1024 * 1024).to_i,
        download_path: data["storage"].presence || ""
      )
    end

    def parse_history_item(data)
      Base::TorrentInfo.new(
        hash: data["nzo_id"],
        name: data["name"],
        progress: 100,
        state: normalize_history_state(data["status"]),
        size_bytes: data["bytes"].to_i,
        download_path: data["storage"].presence || ""
      )
    end

    def normalize_queue_state(status)
      case status&.downcase
      when "downloading"
        :downloading
      when "paused"
        :paused
      when "queued", "grabbing"
        :queued
      else
        :queued
      end
    end

    def normalize_history_state(status)
      case status&.downcase
      when "completed"
        :completed
      when "failed"
        :failed
      else
        :completed
      end
    end
  end
end
