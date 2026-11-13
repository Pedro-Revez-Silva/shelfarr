# frozen_string_literal: true

module AndroidUpdates
  # Plain-text status for operators (rake tasks). Contains no URLs beyond the
  # catalog's origin.
  class StatusReport
    def initialize(configuration: Configuration.current, store: Store.new)
      @configuration = configuration
      @store = store
    end

    def lines
      return [ "Android builds are not offered: #{@configuration.error}" ] if @configuration.misconfigured?
      return [ "Android builds are not offered (ANDROID_UPDATE_CHANNELS is empty)." ] unless @configuration.any_enabled?

      status = @store.status
      lines = [ "Catalog: #{@configuration.source_label}", "Last check: #{status['checked_at'] || 'never'}" ]
      @configuration.channels.each { |channel| lines << channel_line(channel, status.dig("channels", channel) || {}) }
      lines
    end

    private

    def channel_line(channel, entry)
      ready = @store.ready_release(channel)
      state = ready ? "serving #{ready.version_name} (#{ready.version_code})" : "nothing to serve yet"
      problem = entry["error"] ? ", last problem: #{entry['error']}" : ""
      "#{channel}: #{state}#{problem}"
    end
  end
end
