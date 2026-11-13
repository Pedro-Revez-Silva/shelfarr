# frozen_string_literal: true

require "digest"

module AndroidUpdates
  # Brings the server's Android cache up to date: reads the publisher catalog,
  # picks the highest compatible version code for each enabled channel, then
  # downloads, verifies and promotes it. Runs from a background job or the
  # operator's rake task, never from a web request.
  #
  # Anything that goes wrong (network, catalog, checksum, disk) leaves the
  # last promoted build in place and is recorded as a short category.
  class Refresher
    Outcome = Data.define(:status, :channels) do
      def ok?
        status == :ok && channels.values.none? { |channel| channel[:error] }
      end
    end

    class IntegrityError < StandardError; end

    # Avoids repeated downloads when a server restarts or the job reruns.
    MIN_INTERVAL = 5.minutes
    TIMESTAMP = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/

    def initialize(configuration: Configuration.current, store: Store.new, fetcher: nil, clock: -> { Time.current })
      @configuration = configuration
      @store = store
      @policy = configuration.source_policy
      @fetcher = fetcher || Fetcher.new(@policy)
      @clock = clock
    end

    def call(force: false)
      return Outcome.new(status: :misconfigured, channels: {}) if @configuration.misconfigured?
      return Outcome.new(status: :disabled, channels: {}) unless @configuration.any_enabled?

      outcome = @store.with_refresh_lock { refresh(force) }
      outcome == :busy ? Outcome.new(status: :busy, channels: {}) : outcome
    end

    private

    def refresh(force)
      now = @clock.call
      previous_status = @store.status
      return Outcome.new(status: :skipped, channels: {}) if !force && recently_checked?(previous_status, now)

      @store.clear_staging!
      catalog, error = load_catalog
      channels = @configuration.channels.index_with do |channel|
        error ? { result: "kept", error: error } : refresh_channel(channel, catalog)
      end
      record(previous_status, channels, now)
      Outcome.new(status: :ok, channels: channels)
    end

    def recently_checked?(status, now)
      value = status["checked_at"]
      return false unless value.is_a?(String) && value.match?(TIMESTAMP)

      checked_at = Time.iso8601(value)
      checked_at > now - MIN_INTERVAL && checked_at <= now
    end

    # Returns [catalog, nil] or [nil, error category].
    def load_catalog
      catalog = Catalog.parse(@fetcher.catalog(@configuration.catalog_uri), policy: @policy)
      if catalog.skipped.positive?
        Rails.logger.info "[AndroidUpdates] Skipped #{catalog.skipped} catalog entries this server cannot use"
      end
      [ catalog, nil ]
    rescue Fetcher::Error, Catalog::Invalid => e
      category = e.is_a?(Fetcher::Error) ? "catalog_#{e.category}" : "catalog_invalid"
      Rails.logger.warn "[AndroidUpdates] Catalog from #{@configuration.source_label} unavailable (#{category}): #{e.message}"
      [ nil, category ]
    end

    def refresh_channel(channel, catalog)
      current = @store.promotion(channel).current
      # A build this server can no longer serve does not hold the channel back.
      current = nil unless current&.compatible?
      candidates = catalog.for_channel(channel, @configuration.package_for(channel)).select(&:compatible?)
      return { result: "kept", error: "version_conflict" } if conflicting?(candidates)

      best = candidates.max_by(&:version_code)
      return { result: "kept", error: "no_compatible_release" } unless best

      if current && best.version_code < current.version_code
        # The publisher withdrew a build or the catalog is stale: never step back.
        return { result: "kept", version_code: current.version_code, note: "catalog_older" }
      end
      if current && best.version_code == current.version_code
        return { result: "kept", error: "version_conflict" } unless best.same_build?(current)
        return { result: "kept", version_code: current.version_code } if @store.intact?(channel, current)

        Rails.logger.warn "[AndroidUpdates] #{channel} cached build #{current.version_code} is damaged; downloading again"
        @store.discard_apk(channel, current)
      end

      download_and_promote(channel, best)
    end

    def conflicting?(candidates)
      candidates.group_by(&:version_code).values.any? do |same_code|
        same_code.uniq { |release| [ release.sha256, release.size_bytes, release.version_name ] }.size > 1
      end
    end

    def download_and_promote(channel, release)
      staged = @store.stage { |file| download(release, file) }
      @store.promote!(channel, release, staged, promoted_at: @clock.call)
      staged = nil
      Rails.logger.info "[AndroidUpdates] #{channel}: cached #{release.version_name} (#{release.version_code})"
      { result: "promoted", version_code: release.version_code }
    rescue Fetcher::Error => e
      failure(channel, "download_#{e.category}", e.message)
    rescue IntegrityError => e
      failure(channel, "integrity_mismatch", e.message)
    rescue SystemCallError, IOError => e
      failure(channel, "storage_error", e.class.name)
    ensure
      @store.discard_staged(staged)
    end

    def download(release, file)
      digest = Digest::SHA256.new
      size = @fetcher.artifact(URI.parse(release.source_url), max_bytes: release.size_bytes) do |chunk|
        digest.update(chunk)
        file.write(chunk)
      end
      raise IntegrityError, "received #{size} of #{release.size_bytes} bytes" unless size == release.size_bytes
      raise IntegrityError, "SHA-256 does not match the catalog" unless digest.hexdigest == release.sha256
    end

    def failure(channel, category, message)
      Rails.logger.warn "[AndroidUpdates] #{channel}: kept the previous build (#{category}): #{message}"
      { result: "kept", error: category }
    end

    def record(previous, channels, now)
      timestamp = now.utc.iso8601
      entries = (previous["channels"].is_a?(Hash) ? previous["channels"] : {}).slice(*Configuration::CHANNELS)
      channels.each do |channel, outcome|
        entry = { "checked_at" => timestamp, "result" => outcome[:result], "error" => outcome[:error] }
        entry["succeeded_at"] = outcome[:error] ? entries.dig(channel, "succeeded_at") : timestamp
        entries[channel] = entry.compact
      end
      @store.write_status("checked_at" => timestamp, "source" => @configuration.source_label, "channels" => entries)
    rescue SystemCallError, IOError => e
      Rails.logger.warn "[AndroidUpdates] Could not record refresh status: #{e.class.name}"
    end
  end
end
