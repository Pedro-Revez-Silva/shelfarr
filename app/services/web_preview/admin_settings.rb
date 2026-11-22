# frozen_string_literal: true

module WebPreview
  class AdminSettings
    Unknown = Class.new(StandardError)

    CHOICES = {
      indexer_provider: [ [ "none", "None", "Use only direct book sources." ], [ "prowlarr", "Prowlarr", nil ], [ "jackett", "Jackett", nil ], [ "newznab", "NZBHydra2 / Newznab", nil ] ],
      library_platform: [ [ "audiobookshelf", "Audiobookshelf", nil ], [ "bookorbit", "BookOrbit", nil ], [ "grimmory", "Grimmory", nil ] ],
      completed_download_import_mode: [
        [ "copy", "Copy", "Keeps the download and uses extra disk space." ],
        [ "move", "Move", "Removes the download, which can stop torrent seeding." ],
        [ "hardlink", "Hardlink", "Keeps the download without duplicate data. Edits through either name affect both. Falls back to copy across filesystems." ],
        [ "reference", "Reference", "Puts a link to the download in the library without copying, for debrid or rclone mounts. The link breaks if the download is removed." ]
      ],
      oidc_default_role: [ [ "user", "User", nil ], [ "admin", "Admin", nil ] ],
      metadata_source: [ [ "auto", "All enabled sources", nil ], [ "hardcover", "Hardcover only", nil ], [ "google_books", "Google Books only", nil ], [ "openlibrary", "Open Library only", nil ], [ "comic_vine", "Comic Vine only", nil ] ],
      telegram_update_mode: [ [ "polling", "Polling", "Works for local installs." ], [ "webhook", "Webhook", "For public HTTPS addresses." ] ],
      default_request_format: SettingsService::DEFAULT_REQUEST_FORMAT_OPTIONS.map { |label, value| [ value, label, nil ] },
      indexer_search_scope: SettingsService::INDEXER_SEARCH_SCOPES.map { |scope| [ scope, *SettingsService::INDEXER_SEARCH_SCOPE_OPTIONS.fetch(scope).values_at(:label, :description) ] }
    }.freeze
    EVENT_KEYS = %i[webhook_events discord_events telegram_notification_events].freeze
    URL_LIST_KEYS = %i[anna_archive_url zlibrary_url].freeze
    URL_KEYS = %i[prowlarr_url jackett_url newznab_url audiobookshelf_url bookorbit_url grimmory_url flaresolverr_url gutenberg_url librivox_url oidc_issuer webhook_url hardcover_oauth_redirect_uri].freeze
    CODE_KEYS = %i[ebook_path_template ebook_filename_template audiobook_path_template audiobook_filename_template comicbook_path_template comicbook_filename_template library_import_file_mode library_import_folder_mode].freeze
    LIST_KEYS = %i[enabled_languages ebook_approved_formats ebook_rejected_formats ebook_preferred_formats audiobook_approved_formats audiobook_rejected_formats audiobook_preferred_formats].freeze
    PLACEHOLDERS = {
      library_import_file_mode: "0664", library_import_folder_mode: "0775",
      ebook_min_file_size: "50 MB", ebook_max_file_size: "50 MB", audiobook_min_file_size: "50 MB", audiobook_max_file_size: "50 MB",
      ebook_preferred_formats: "epub, pdf", ebook_rejected_formats: "epub, pdf", ebook_approved_formats: "epub, pdf",
      audiobook_preferred_formats: "m4b, mp3", audiobook_rejected_formats: "m4b, mp3", audiobook_approved_formats: "m4b, mp3",
      enabled_languages: "en, fr, de", anna_archive_url: "https://annas-archive.example", zlibrary_url: "https://z-library.example",
      discord_webhook_url: "https://discord.com/api/webhooks/…"
    }.freeze
    RANGES = {
      ebooks_com_search_limit: [ 1, EbooksComClient::MAX_RESULTS ],
      health_check_interval: [ SettingsService::MIN_HEALTH_CHECK_INTERVAL, nil ],
      auto_select_confidence_threshold: [ 0, 100 ],
      min_match_confidence: [ 0, 100 ]
    }.freeze
    WARNINGS = {
      auth_disabled: "This removes password and two-factor sign-in for everyone. Only use it on a trusted private network.",
      allow_nonatomic_nfs_directory_publication: "Safety override: use only on an NFS export that nothing else writes to.",
      precreate_download_archives: "Cached archives use tmp/downloads, and reference-mode folders use the system temporary folder. Keep both on disk, not in memory, before downloading large books."
    }.freeze
    PLATFORM_FIELDS = {
      "audiobookshelf" => %i[audiobookshelf_url audiobookshelf_api_key],
      "bookorbit" => %i[bookorbit_url bookorbit_username bookorbit_password],
      "grimmory" => %i[grimmory_url grimmory_username grimmory_password]
    }.freeze
    INDEXER_FIELDS = {
      "prowlarr" => %i[prowlarr_url prowlarr_api_key prowlarr_tags],
      "jackett" => %i[jackett_url jackett_api_key jackett_indexer_filter],
      "newznab" => %i[newznab_url newznab_api_key]
    }.freeze
    CUSTOM_CATEGORY_KEYS = %i[indexer_custom_audiobook_categories indexer_custom_ebook_categories indexer_custom_comicbook_categories].freeze
    MAX_VALUE_LENGTH = 10_000
    WRITE_ONLY_ADDRESSES = %i[webhook_url].freeze

    def initialize(base_url:)
      @base_url = base_url
    end

    def representation
      SettingsService.seed_defaults!
      {
        categories: AdminSettingsLayout::CATEGORIES.map { |category| category_json(category) },
        notes: notes,
        roles: roles
      }
    end

    def save(group_id, submitted)
      group = AdminSettingsLayout.group(group_id) or raise Unknown, "Unknown settings group"
      values = normalize_submission(submitted)
      allowed = AdminSettingsLayout.keys_for(group).map(&:to_s)
      stray = values.keys - allowed
      raise Unknown, "These settings are not part of #{group[:title]}: #{stray.first(5).join(', ')}" if stray.any?

      candidates = values.reject { |key, value| managed_by(key.to_sym) || ServerSettings::Change.unchanged_secret?(key, value) || kept_address?(key, value) }
        .to_h { |key, value| [ key, value.nil? ? "" : value ] }
      lookup = ->(key) { values.key?(key.to_s) ? values[key.to_s] : SettingsService.get(key) }
      ServerSettings::Change.new(lookup: lookup).apply(candidates.to_a)
    end

    def group_json(group_id)
      group = AdminSettingsLayout.group(group_id) or raise Unknown, "Unknown settings group"
      group_payload(group)
    end

    private

    attr_reader :base_url

    def normalize_submission(submitted)
      raise Unknown, "Send the settings as an object of names and values" unless submitted.is_a?(Hash)

      submitted.to_h { |key, value| [ key.to_s, scalar_or_list(key, value) ] }
    end

    def write_only?(key)
      SettingsService.secret_setting_key?(key) || WRITE_ONLY_ADDRESSES.include?(key.to_sym)
    end

    ADDRESS_ORIGIN = %r{\A(https?)://(?:[^/?#@\s]*@)?(\[[0-9a-f:.]+\]|[^/?#:@\s\[\]]+)}i

    def address_origin(value)
      match = value.to_s.strip.match(ADDRESS_ORIGIN)
      "#{match[1].downcase}://#{match[2]}" if match
    end

    def kept_address?(key, value)
      WRITE_ONLY_ADDRESSES.include?(key.to_sym) && value.is_a?(String) && value.gsub(/[[:space:]\u0000]/, "").empty?
    end

    def managed_by(key)
      return "DISABLE_AUTH" if key == :auth_disabled && SettingsService.auth_disabled_by_environment?

      SettingsService.env_override_name(key) if SettingsService.env_managed?(key)
    end

    def scalar_or_list(key, value)
      return nil if value.nil? && WRITE_ONLY_ADDRESSES.include?(key.to_sym)

      case value
      when String
        raise Unknown, "#{key} is too long" if value.length > MAX_VALUE_LENGTH

        value
      when true, false then value.to_s
      when Integer then value.to_s
      when Array
        raise Unknown, "#{key} must be a list of text" unless value.all?(String) && value.sum(&:length) <= MAX_VALUE_LENGTH

        value
      else
        raise Unknown, "#{key} must be text, a number, true or false"
      end
    end

    def category_json(category)
      { id: category[:id], title: category[:title], summary: category[:summary], groups: category[:groups].map { |group| group_payload(group) } }
    end

    def group_payload(group)
      {
        id: group[:id],
        heading: group[:heading],
        title: group[:title],
        summary: group[:summary],
        toggle: group[:toggle]&.to_s,
        fields: group[:fields].map { |key| field(key) },
        advanced: group.fetch(:advanced, []).map { |key| field(key) },
        probes: group.fetch(:probes, []).map { |probe| probe_json(probe) },
        extras: group.fetch(:extras, []),
        notes: group.fetch(:notes, []),
        health: group[:health] && health(group[:health])
      }.compact
    end

    def probe_json(probe)
      json = { id: probe[:id], label: probe[:label], uses: probe[:uses], changes: probe.fetch(:changes, false) }
      probe[:uses] == "draft" ? json.merge(draft_keys: ServerSettings::Probe::POSTED_KEYS) : json
    end

    def health(service)
      record = SystemHealth.find_by(service: service)
      {
        service: service,
        status: record&.status,
        message: SecretRedaction.call(record&.message.presence),
        checked_at: record&.last_check_at&.iso8601
      }.compact.merge(status: record&.status)
    end

    def roles
      immediate = SettingsService.get(:immediate_search_enabled, default: false)
      member_requests = immediate || SettingsService.auto_approve_requests? ? "Yes, searched straight away" : "Yes, searched on the next queue run"
      [
        { action: "Request a book", member: member_requests, administrator: "Yes", setting: { category: "policy", group: "new_requests", key: "auto_approve_requests" } },
        { action: "Choose a copy, search again or add a link", member: "No", administrator: "Yes" },
        { action: "Upload a book file", member: yes_no(SettingsService.user_uploads_allowed?), administrator: "Yes", setting: { category: "people", group: "member_permissions", key: "allow_user_uploads" } },
        { action: "Connect Hardcover with a personal API key", member: yes_no(HardcoverIntegration.personal_tokens_allowed?), administrator: yes_no(HardcoverIntegration.personal_tokens_allowed?),
          setting: { category: "sources", group: "hardcover_accounts", key: "hardcover_allow_personal_access" } },
        { action: "See sources, folders, other accounts and diagnostics", member: "No", administrator: "Yes" }
      ]
    end

    def field(key)
      definition = SettingsService::DEFINITIONS.fetch(key)
      managed = managed_by(key)
      secret = write_only?(key)
      {
        key: key.to_s,
        label: AdminSettingsLayout::LABELS.fetch(key) { SettingsService.label_for(key) },
        description: description(key, definition),
        input: input(key, definition, secret),
        value: secret ? nil : value(key),
        default: secret ? nil : presented_default(key, definition),
        configured: secret ? SettingsService.get(key).present? : nil,
        clearable: WRITE_ONLY_ADDRESSES.include?(key) || nil,
        shown: WRITE_ONLY_ADDRESSES.include?(key) ? address_origin(SettingsService.get(key)) : nil,
        managed_by: managed,
        options: options(key),
        min: RANGES.dig(key, 0),
        max: RANGES.dig(key, 1),
        placeholder: PLACEHOLDERS[key],
        warning: WARNINGS[key],
        visible_when: visible_when(key)
      }.compact.merge(value: secret ? nil : value(key))
    end

    def description(key, definition)
      text = definition[:description].to_s
      key.to_s.end_with?("_path_template", "_filename_template") ? text.split(" Variables include").first : text
    end

    def input(key, definition, secret)
      return "secret" if secret
      return "order" if key == :preferred_download_types
      return "choice" if CHOICES.key?(key)
      return "events" if EVENT_KEYS.include?(key)
      return "url_list" if URL_LIST_KEYS.include?(key)
      return "library" if key.to_s.end_with?("_library_id")
      return "libraries" if key.to_s.end_with?("_scan_library_ids")
      return "list" if LIST_KEYS.include?(key)
      return "toggle" if definition[:type] == "boolean"
      return "number" if definition[:type] == "integer"
      return "url" if URL_KEYS.include?(key)
      return "code" if CODE_KEYS.include?(key)
      return "country" if key == :ebooks_com_country_code

      "text"
    end

    def value(key)
      return SettingsService.auth_disabled? if key == :auth_disabled

      case key
      when :indexer_provider then SettingsService.get(key).presence || SettingsService.active_indexer_provider
      when :preferred_download_types then SettingsService.preferred_download_types
      when *EVENT_KEYS, :audiobookshelf_audiobook_scan_library_ids, :audiobookshelf_ebook_scan_library_ids, :audiobookshelf_comicbook_scan_library_ids
        SettingsService.get(key).to_s.split(",").map(&:strip).reject(&:blank?)
      when *URL_LIST_KEYS then SettingsService.get(key).to_s.split(/[,\s]+/).map(&:strip).reject(&:blank?).uniq
      when *LIST_KEYS then Array(SettingsService.get(key)).map(&:to_s)
      else
        stored = SettingsService.get(key)
        stored.is_a?(Array) ? stored.join(", ") : stored
      end
    end

    def presented_default(key, definition)
      default = definition[:default]
      return nil if default.nil? || default == "" || default == "[]"
      return default.split(/[,\s]+/).reject(&:blank?) if URL_LIST_KEYS.include?(key)
      return nil if key == :preferred_download_types || LIST_KEYS.include?(key) || EVENT_KEYS.include?(key)

      default
    end

    def options(key)
      return CHOICES[key].map { |value, label, hint| { value: value, label: label, description: hint }.compact } if CHOICES.key?(key)
      return SettingsService.download_type_options.map { |option| { value: option[:value], label: option[:label], description: option[:description] } } if key == :preferred_download_types

      if EVENT_KEYS.include?(key)
        known = OutboundNotifications::WebhookDelivery::EVENTS
        extra = value(key) - known
        return (known + extra).map { |event| { value: event, label: event.delete_prefix("request_").humanize.then { |name| "Request #{name.downcase}" } } }
      end
      nil
    end

    def visible_when(key)
      platform = PLATFORM_FIELDS.find { |_, keys| keys.include?(key) }&.first
      return { key: "library_platform", in: [ platform ] } if platform

      provider = INDEXER_FIELDS.find { |_, keys| keys.include?(key) }&.first
      return { key: "indexer_provider", in: [ provider ] } if provider
      return { key: "indexer_search_scope", in: [ "custom" ] } if CUSTOM_CATEGORY_KEYS.include?(key)

      nil
    end

    def yes_no(allowed)
      allowed ? "Yes" : "No"
    end

    def notes
      redirect = HardcoverIntegration.redirect_uri(base_url)
      {
        path_variables: "Use {author}, {authorSort}, {title}, {titleSort}, {year}, {publisher}, {language}, {series}, {seriesSort}, {seriesNum:00}, and {narrator}. Optional text inside braces is kept only when the value exists, such as {series/} or {series - }.",
        hardcover_app: {
          create_url: "https://hardcover.app/account/developer-apps/new",
          scopes: HardcoverIntegration::OAUTH_SCOPES.join(" "),
          redirect_uri: redirect,
          redirect_uri_acceptable: HardcoverIntegration.redirect_uri_acceptable?(redirect)
        }
      }
    end
  end
end
