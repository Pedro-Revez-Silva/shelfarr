# frozen_string_literal: true

module WebPreview
  class AudibleBackupJson
    SIGN_IN_PURPOSE = "web_preview/audible_sign_in"
    SIGN_IN_ADDRESS_BYTES = 16.kilobytes
    BEARER_SHAPED = /\S{#{OwnedLibraryConnectionWorkflow::SHORTEST_COMPANION_BEARER},}/
    ADDRESS = %r{[a-z][a-z0-9+.-]*://[^\s"'<>]+}i
    ACTIVE_LABELS = { "queued" => "Queued", "starting" => "Starting", "downloading" => "Backing up", "processing" => "Importing" }.freeze

    def self.sign_in_token(connection, user, session_id)
      key = Rails.application.key_generator.generate_key(SIGN_IN_PURPOSE, 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, [ connection.id, user.id, session_id ].join("\n"))
    end

    def self.sign_in_token_matches?(connection, user, session_id, submitted)
      submitted.is_a?(String) && submitted.bytesize == 64 && session_id.present? &&
        ActiveSupport::SecurityUtils.secure_compare(sign_in_token(connection, user, session_id), submitted)
    end

    def self.revision(connection)
      return "unsaved" unless connection.persisted?

      imports = connection.owned_media_imports
      items = connection.owned_library_items
      marks = [
        connection.updated_at, imports.maximum(:updated_at), imports.count, items.maximum(:updated_at), items.count
      ].map { |mark| mark.respond_to?(:utc) ? mark.utc.iso8601(6) : mark.to_s }
      Digest::SHA256.hexdigest(marks.join("|")).first(16)
    end

    def self.catalogue_generation(connection)
      return "unsaved" unless connection.persisted?

      titles = connection.owned_library_items.active
      marks = [ connection.last_synced_at, titles.count, titles.maximum(:updated_at) ]
        .map { |mark| mark.respond_to?(:utc) ? mark.utc.iso8601(6) : mark.to_s }
      Digest::SHA256.hexdigest(marks.join("|")).first(16)
    end

    def self.sign_in_host?(host)
      host = host.to_s.downcase
      LibationCompanionClient::AUTH_HOST_SUFFIXES.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
    end

    def self.safe_sign_in_link(value)
      return nil unless value.is_a?(String) && value.bytesize <= SIGN_IN_ADDRESS_BYTES

      uri = parse_address(value)
      return nil if RemoteResult.failed?(uri)

      uri.to_s if uri.is_a?(URI::HTTPS) && sign_in_host?(uri.host) && uri.userinfo.nil?
    end

    def self.parse_address(value)
      URI.parse(value)
    rescue URI::InvalidURIError => error
      RemoteResult::Failed.new(error)
    end

    def initialize(workflow, user:)
      @workflow = workflow
      @connection = workflow.connection
      @user = user
    end

    def state(summary, revision:, catalogue_generation:)
      {
        connection: connection_json(summary),
        sign_in: sign_in_json(summary),
        sync: sync_json(summary),
        library: { total: summary.library_total_items, purchased: summary.purchased_items, subscription: summary.subscription_items },
        active_backups: { total: summary.active_backup_total, counts: counts_json(summary.active_backup_counts) },
        existing_backup: existing_backup_json(summary),
        automation: automation_json,
        marketplaces: LibationCompanionClient::AUDIBLE_MARKETPLACES.map { |value| { value: value, label: LibationCompanionClient::AUDIBLE_MARKETPLACE_NAMES.fetch(value) } },
        working: working?(summary),
        revision: revision,
        catalogue_generation: catalogue_generation
      }
    end

    def catalogue(listing, generation:)
      purchased = listing.items.select { |item| item.purchased? && !item.book&.acquired? }
      resolutions = purchased.any? ? OwnedLibraryBookMatcher.new.resolve_many(purchased) : {}
      {
        query: listing.query,
        page: listing.page,
        pages: listing.total_pages,
        total: listing.total_items,
        synced: @connection.last_synced_at.present?,
        generation: generation,
        items: listing.items.map { |item| item_json(item, resolutions[item.id]) }
      }
    end

    def redact(text)
      return nil if text.nil?

      masked = without_secrets(text).gsub(ADDRESS) { |address| shown_address(address) }
      SecretRedaction.call(masked.gsub(BEARER_SHAPED, SecretRedaction::MASK))
    end

    def identity(text)
      return nil if text.nil?

      without_secrets(text)
    end

    private

    def without_secrets(text)
      companion_secrets.reduce(text.to_s) { |result, secret| result.gsub(secret, SecretRedaction::MASK) }
    end

    def shown_version(value)
      OwnedLibraryConnectionWorkflow.reportable_version(value, @connection.client.secret_values)
    end

    def companion_secrets
      @companion_secrets ||= @connection.client.secret_values.sort_by { |secret| -secret.length }
    end

    def shown_address(address)
      uri = URI.parse(address)
      return SecretRedaction::MASK if uri.userinfo.present? || uri.host.blank?

      origin = uri.class.new(uri.scheme, nil, uri.host, uri.port, nil, nil, nil, nil, nil).to_s
      return "#{origin}/#{SecretRedaction::MASK}" if self.class.sign_in_host?(uri.host)

      shown = uri.class.new(uri.scheme, nil, uri.host, uri.port, nil, uri.path, nil, nil, nil).to_s
      uri.query.present? || uri.fragment.present? ? "#{shown}?#{SecretRedaction::MASK}" : shown
    rescue URI::Error
      SecretRedaction::MASK
    end

    def persisted_and_enabled?
      @connection.persisted? && @connection.enabled?
    end

    def operation_locked?(summary)
      summary.auth_active? || @connection.sync_active? || summary.active_backup_total.positive?
    end

    def working?(summary)
      summary.auth_active? || @connection.sync_active? || summary.active_backup_total.positive? || summary.backlog_backup_remaining.positive?
    end

    def connection_json(summary)
      problem = redact(summary.companion_error.presence)
      {
        saved: @connection.persisted?,
        url: @connection.url.to_s,
        default_url: OwnedLibraryConnection.default_libation_url,
        bridge_token_saved: @connection.bridge_token.present?,
        token_file_managed: @connection.client.token_file_managed?,
        enabled: @connection.enabled?,
        allow_private_network: @connection.allow_private_network?,
        timeout_seconds: @connection.timeout_seconds,
        companion_version: shown_version(@connection.companion_version),
        provider_version: shown_version(@connection.provider_version),
        status: problem ? "unavailable" : (@connection.enabled? ? (summary.companion_busy? ? "busy" : "ready") : "needs_setup"),
        problem: problem,
        locked: @connection.persisted? && operation_locked?(summary)
      }
    end

    def sign_in_json(summary)
      return { state: "not_ready", accounts: [], accounts_paused: false, locked: false, reregister_default: false } unless persisted_and_enabled?

      state = if summary.auth_starting? then "starting"
      elsif summary.auth_pending? then "pending"
      elsif summary.audible_connected? then "connected"
      else "needs_sign_in"
      end
      answer = {
        state: state,
        accounts: summary.accounts.map { |account| account_json(account) },
        accounts_paused: summary.companion_busy? && summary.audible_connected? && summary.accounts.empty?,
        locked: !summary.auth_active? && (@connection.sync_active? || summary.active_backup_total.positive?),
        reregister_default: summary.audible_connected?
      }
      return answer unless state == "pending"

      answer.merge(
        login_url: self.class.safe_sign_in_link(summary.login_url),
        sign_in_token: self.class.sign_in_token(@connection, @user, @connection.auth_session_id.to_s),
        expires_at: @connection.auth_expires_at&.iso8601
      )
    end

    def account_json(account)
      {
        label: identity(account.name.presence || account.account),
        marketplace: LibationCompanionClient::AUDIBLE_MARKETPLACE_NAMES.fetch(account.locale.to_s.downcase, "Unknown marketplace"),
        authenticated: account.authenticated == true
      }
    end

    def sync_json(summary)
      backups_running = summary.active_backup_total.positive?
      {
        state: summary.sync_state,
        recoverable: summary.sync_recoverable,
        job_recorded: @connection.sync_job_id.present?,
        refreshing: @connection.last_synced_at.present?,
        started_at: @connection.sync_started_at&.iso8601,
        last_synced_at: @connection.last_synced_at&.iso8601,
        error: summary.sync_state == "failed" ? redact(@connection.last_sync_error.presence) : nil,
        action: sync_action(summary, backups_running),
        available: persisted_and_enabled? && !(summary.auth_active? || (@connection.sync_active? && !summary.sync_recoverable) || backups_running || !summary.audible_connected?)
      }
    end

    def sync_action(summary, backups_running)
      if backups_running then "Backups running…"
      elsif !summary.audible_connected? then "Connect Audible first"
      elsif summary.sync_recoverable then @connection.sync_job_id.present? ? "Check sync status" : "Recover sync"
      elsif @connection.queued? then "Sync queued…"
      elsif @connection.syncing? then "Syncing…"
      elsif @connection.failed? then "Retry sync"
      else "Sync library"
      end
    end

    def existing_backup_json(summary)
      {
        available: summary.backlog_backup_available,
        prompt: summary.backlog_backup_prompt,
        total: summary.backlog_backup_total,
        remaining: summary.backlog_backup_remaining,
        processed: summary.backlog_backup_processed,
        counts: counts_json(summary.backlog_backup_counts)
      }
    end

    def automation_json
      owner = @connection.automatic_backup_user
      {
        scheduled_sync_enabled: @connection.scheduled_sync_enabled?,
        interval_minutes: @connection.scheduled_sync_interval_minutes,
        intervals: OwnedLibraryConnectionWorkflow::AUTOMATION_INTERVAL_OPTIONS.map { |label, minutes| { minutes: minutes, label: label } },
        next_sync_at: @connection.scheduled_sync_enabled? ? @connection.next_scheduled_sync_at&.iso8601 : nil,
        automatic_backup_enabled: @connection.automatic_backup_enabled?,
        owner: @connection.automatic_backup_enabled? ? owner&.name : nil,
        owner_ready: @connection.automatic_backup_ready? && owner&.admin? == true,
        baseline_ready: @connection.automatic_backup_baseline_ready?,
        first_sync_done: @connection.last_synced_at.present?
      }
    end

    def counts_json(counts)
      OwnedMediaImport::STATUSES.filter_map { |status| { status: status, count: counts[status] } if counts[status].to_i.positive? }
    end

    def item_json(item, resolution)
      {
        id: item.id.to_s,
        title: identity(item.display_title.to_s),
        author: identity(item.author.presence || item.external_id.to_s),
        ownership: item.ownership_type,
        book_id: (item.book_id.to_s if item.book&.acquired?),
        **backup_json(item, resolution)
      }
    end

    def backup_json(item, resolution)
      latest = item.latest_import
      origin = if latest.nil? then nil
      elsif latest.pending? || latest.dispatched_at.present? then "existing"
      elsif latest.automatic? then "automatic"
      else "manual"
      end
      base = { origin: origin, detail: nil, action: nil }
      return base.merge(state: "not_eligible") unless item.purchased?
      return base.merge(state: "in_shelfarr") if item.book&.acquired?

      state, detail = item_state(item, latest, resolution)
      base.merge(state: state, detail: detail, action: item_action(item, latest, resolution))
    end

    def item_state(item, latest, resolution)
      if resolution&.matched? then [ "on_server", nil ]
      elsif latest&.pending? then [ "waiting", nil ]
      elsif latest&.active? then [ latest.recoverable? ? "stalled" : latest.status, nil ]
      elsif latest&.failed? then [ "failed", redact(latest.error_message.presence) ]
      elsif resolution&.conflict? then [ "possible_match", nil ]
      elsif item.downloaded? then [ "in_libation", nil ]
      else [ "not_backed_up", nil ]
      end
    end

    def item_action(item, latest, resolution)
      pending = latest&.pending?
      active = latest&.active?
      recoverable = active && latest.recoverable?
      label = if @connection.sync_active? then "Library syncing…"
      elsif resolution&.matched? then "Already in Shelfarr"
      elsif pending then "Waiting in batch…"
      elsif recoverable then "Check status"
      elsif active then "#{ACTIVE_LABELS.fetch(latest.status, 'Queued')}…"
      elsif resolution&.conflict? then "Back up separately"
      elsif latest&.failed? then "Retry backup"
      elsif item.downloaded? then "Import into Shelfarr"
      else "Back up"
      end
      {
        label: label,
        separate_edition: resolution&.conflict? == true,
        available: @connection.enabled? && !(pending || (active && !recoverable) || @connection.sync_active? || resolution&.matched?)
      }
    end
  end
end
