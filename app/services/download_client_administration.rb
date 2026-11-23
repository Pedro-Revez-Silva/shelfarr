# frozen_string_literal: true

class DownloadClientAdministration
  ATTRIBUTES = %i[
    name client_type url username password api_key clear_api_key category download_path enabled
    torrent_verification_max_attempts torrent_verification_wait_time
  ].freeze
  CLEAR_API_KEY = "1"
  DIRECTIONS = %i[up down].freeze

  Update = Data.define(:saved, :api_key_submitted, :clear_api_key) do
    def saved?
      saved
    end
  end

  UNCLASSIFIED_FAILURE = "the client did not accept the connection. Check the address and sign-in"

  Test = Data.define(:success, :message, :summary) do
    def success?
      success
    end
  end

  Changes = Data.define(:attributes, :api_key_submitted, :clear_api_key)

  class << self
    def ordered
      DownloadClient.order(client_type: :asc, priority: :asc)
    end

    def create(attributes)
      client = DownloadClient.new(attributes.to_h.symbolize_keys.except(:clear_api_key))
      saved = DownloadClient.transaction do
        client.priority = next_priority_for(client.client_type)
        client.save
      end
      settle if saved
      client
    end

    def update(client, attributes)
      result = apply_update(client, attributes)
      settle if result.saved?
      result
    end

    def apply_update(client, attributes)
      changes = changes_from(attributes)
      Update.new(saved: client.update(changes.attributes), api_key_submitted: changes.api_key_submitted, clear_api_key: changes.clear_api_key)
    end

    def destroy(client)
      client.destroy
      settle
      client
    end

    def test(client)
      outcome = test_outcome(client)
      run_health_check
      outcome
    end

    def move(client, direction, expected_neighbour: nil)
      raise ArgumentError, "Unknown direction" unless DIRECTIONS.include?(direction)

      DownloadClient.transaction do
        same_type_clients = DownloadClient.where(client_type: client.client_type).order(priority: :asc).to_a
        index = same_type_clients.index(client)
        next :unchanged unless index

        swap_index = direction == :up ? index - 1 : index + 1
        next(expected_neighbour ? :stale : :unchanged) if swap_index < 0 || swap_index >= same_type_clients.length

        mover = same_type_clients[index]
        other = same_type_clients[swap_index]
        next :stale if expected_neighbour && other.id.to_s != expected_neighbour
        next :tied if mover.priority == other.priority

        mover.priority, other.priority = other.priority, mover.priority
        mover.save!
        other.save!
        :moved
      end
    end

    def settle
      run_health_check
      sync_download_monitor
    end

    private

    def changes_from(attributes)
      changes = attributes.to_h.symbolize_keys
      api_key_submitted = changes[:api_key].present?
      changes.delete(:password) if changes[:password].blank?
      clear_api_key = changes.delete(:clear_api_key) == CLEAR_API_KEY
      if clear_api_key
        changes[:api_key] = nil
      elsif changes[:api_key].blank?
        changes.delete(:api_key)
      end
      Changes.new(attributes: changes, api_key_submitted: api_key_submitted, clear_api_key: clear_api_key)
    end

    def test_outcome(client)
      name = client.name.presence || "this client"
      if RemoteResult.succeeded?(client.test_connection)
        message = "Connection to '#{name}' successful!"
        Test.new(success: true, message: message, summary: message)
      else
        message = "Connection to '#{name}' failed."
        Test.new(success: false, message: message, summary: message)
      end
    rescue StandardError => e
      reason = ConnectionErrorClassifier.with_localhost_hint(ConnectionErrorClassifier.describe(e), client.url)
      known = ConnectionErrorClassifier.classify(e)&.message
      summary = known ? ConnectionErrorClassifier.with_localhost_hint(known, client.url) : UNCLASSIFIED_FAILURE
      Test.new(success: false, message: "Connection to '#{name}' failed: #{reason}", summary: "Connection to '#{name}' failed: #{summary}")
    end

    def next_priority_for(client_type)
      max = DownloadClient.where(client_type: client_type).maximum(:priority) || -1
      max + 1
    end

    def run_health_check
      HealthCheckJob.perform_now(service: "download_client")
    rescue => e
      Rails.logger.warn "[DownloadClientsController] Failed to run download client health check: #{e.message}"
    end

    def sync_download_monitor
      if DownloadClient.enabled.exists?
        DownloadMonitorJob.ensure_running!
      else
        DownloadMonitorJob.clear_schedule!
      end
    rescue => e
      Rails.logger.warn "[DownloadClientsController] Failed to sync download monitor: #{e.message}"
    end
  end
end
