class SettingsService
  DEFAULT_ZLIBRARY_URLS = "https://z-library.sk\nhttps://z-library.bz\nhttps://z-library.rs"

  DOWNLOAD_TYPES = %w[torrent usenet direct].freeze
  LIBRARY_PLATFORMS = %w[audiobookshelf bookorbit].freeze
  INDEXER_SEARCH_SCOPES = %w[broad strict unrestricted custom].freeze
  INDEXER_SEARCH_SCOPE_OPTIONS = {
    "broad" => {
      label: "Broad (recommended)",
      description: "Search Shelfarr's book categories, then supplement with an unrestricted search filtered by match quality."
    },
    "strict" => {
      label: "Strict",
      description: "Search only Shelfarr's default book categories."
    },
    "unrestricted" => {
      label: "Unrestricted",
      description: "Search without category filters and rely on match quality filtering."
    },
    "custom" => {
      label: "Custom",
      description: "Search only the custom category IDs configured below."
    }
  }.freeze
  DEFAULT_INDEXER_CATEGORY_IDS = {
    audiobook: [ 3030 ],
    ebook: [ 7020, 7000 ],
    all_books: [ 3030, 7020, 7000 ]
  }.freeze
  DOWNLOAD_TYPE_OPTIONS = {
    "torrent" => {
      label: "Torrent",
      description: "Tracker and magnet-link releases"
    },
    "usenet" => {
      label: "Usenet",
      description: "NZB releases sent to a usenet client"
    },
    "direct" => {
      label: "Direct",
      description: "Integration downloads such as Anna's Archive, Z-Library, Project Gutenberg, and LibriVox"
    }
  }.freeze

  # Define all expected settings with their defaults and types
  DEFINITIONS = {
    # Indexer Integration
    indexer_provider: { type: "string", default: "", category: "indexer", description: "Active indexer provider. Leave unset on upgrades to keep legacy Prowlarr configuration." },
    indexer_search_scope: { type: "string", default: "broad", category: "indexer", description: "How broadly Shelfarr should search indexer categories." },
    indexer_custom_audiobook_categories: { type: "string", default: "", category: "indexer", description: "Audiobook category IDs separated by commas, spaces, or new lines. Used when search scope is Custom. Leave blank to use Shelfarr defaults." },
    indexer_custom_ebook_categories: { type: "string", default: "", category: "indexer", description: "Ebook category IDs separated by commas, spaces, or new lines. Used when search scope is Custom. Leave blank to use Shelfarr defaults." },
    prowlarr_url: { type: "string", default: "", category: "indexer", description: "Base URL for Prowlarr instance (e.g., http://localhost:9696)" },
    prowlarr_api_key: { type: "string", default: "", category: "indexer", description: "API key from Prowlarr Settings > General" },
    prowlarr_tags: { type: "string", default: "", category: "indexer", description: "Comma-separated tag IDs or names to filter Prowlarr indexers (leave empty for all indexers)" },
    jackett_url: { type: "string", default: "", category: "indexer", description: "Base URL for Jackett instance (e.g., http://localhost:9117)" },
    jackett_api_key: { type: "string", default: "", category: "indexer", description: "API key from Jackett dashboard" },
    jackett_indexer_filter: { type: "string", default: "all", category: "indexer", description: "Jackett indexer filter for Torznab queries. Use 'all' for every indexer, or a specific Jackett filter such as 'tag:books'." },
    newznab_url: { type: "string", default: "", category: "indexer", description: "Newznab-compatible API URL for NZBHydra2 or another Newznab provider (e.g., http://localhost:5076)" },
    newznab_api_key: { type: "string", default: "", category: "indexer", description: "API key from NZBHydra2 or your Newznab provider" },

    # Download Settings (clients are now managed separately via Admin > Download Clients)
    preferred_download_types: { type: "json", default: '["torrent","usenet","direct"]', category: "download", description: "Download types in preference order. Higher-ranked types are preferred when multiple result types are available." },
    download_check_interval: { type: "integer", default: 60, category: "download", description: "Seconds between download status checks" },
    download_enqueue_timeout_minutes: { type: "integer", default: 5, category: "download", description: "Minutes a download may stay queued in Shelfarr before being flagged as never dispatched to the download client" },
    post_processing_source_path_retries: { type: "integer", default: 10, category: "download", description: "Number of post-processing retries while waiting for completed download files to appear" },
    move_completed_downloads: { type: "boolean", default: false, category: "download", description: "Move completed download files into the library instead of copying them. Disable to preserve torrent seeding." },
    remove_completed_usenet_downloads: { type: "boolean", default: true, category: "download", description: "Remove usenet downloads from client after successful import" },

    # Library Platform Integration
    library_platform: { type: "string", default: "audiobookshelf", category: "audiobookshelf", description: "Library platform to sync and scan: audiobookshelf or bookorbit" },
    audiobookshelf_url: { type: "string", default: "", category: "audiobookshelf", description: "Base URL for Audiobookshelf (e.g., http://localhost:13378)" },
    audiobookshelf_api_key: { type: "string", default: "", category: "audiobookshelf", description: "API token from Audiobookshelf user settings" },
    bookorbit_url: { type: "string", default: "", category: "audiobookshelf", description: "Base URL for BookOrbit (e.g., http://localhost:3000)" },
    bookorbit_username: { type: "string", default: "", category: "audiobookshelf", description: "BookOrbit username with library access and scan permissions" },
    bookorbit_password: { type: "string", default: "", category: "audiobookshelf", description: "BookOrbit password used to obtain an API access token" },
    audiobookshelf_audiobook_library_id: { type: "string", default: "", category: "audiobookshelf", description: "Library ID for audiobooks on the active library platform" },
    audiobookshelf_ebook_library_id: { type: "string", default: "", category: "audiobookshelf", description: "Library ID for ebooks on the active library platform" },
    audiobookshelf_library_sync_interval: { type: "integer", default: 3600, category: "audiobookshelf", description: "Seconds between automatic library inventory sync jobs" },

    # Output Paths
    audiobook_output_path: { type: "string", default: "/audiobooks", category: "paths", description: "Directory for completed audiobooks" },
    ebook_output_path: { type: "string", default: "/ebooks", category: "paths", description: "Directory for completed ebooks" },
    audiobook_path_template: { type: "string", default: "{author}/{title}", category: "paths", description: "Folder structure for audiobooks. Variables include {author}, {authorSort}, {title}, {titleSort}, {year}, {publisher}, {language}, {series}, {seriesSort}, {seriesNum:00}, {narrator}. Optional suffix text is supported inside braces, e.g. {series/} or {series - }." },
    ebook_path_template: { type: "string", default: "{author}/{title}", category: "paths", description: "Folder structure for ebooks. Variables include {author}, {authorSort}, {title}, {titleSort}, {year}, {publisher}, {language}, {series}, {seriesSort}, {seriesNum:00}, {narrator}. Optional suffix text is supported inside braces, e.g. {series/} or {series - }." },
    audiobook_filename_template: { type: "string", default: "{author} - {title}", category: "paths", description: "Filename for audiobooks (extension added automatically). Variables include {author}, {authorSort}, {title}, {titleSort}, {year}, {publisher}, {language}, {series}, {seriesSort}, {seriesNum:00}, {narrator}. Optional suffix text is supported inside braces, e.g. {series - }." },
    ebook_filename_template: { type: "string", default: "{author} - {title}", category: "paths", description: "Filename for ebooks (extension added automatically). Variables include {author}, {authorSort}, {title}, {titleSort}, {year}, {publisher}, {language}, {series}, {seriesSort}, {seriesNum:00}, {narrator}. Optional suffix text is supported inside braces, e.g. {series - }." },
    download_remote_path: { type: "string", default: "", category: "paths", description: "Download client path (host path, e.g., /mnt/media/Torrents/Completed)" },
    download_local_path: { type: "string", default: "/downloads", category: "paths", description: "Container path for downloads (e.g., /downloads)" },

    # Queue Settings
    immediate_search_enabled: { type: "boolean", default: false, category: "queue", description: "Start searching immediately when a request is created (instead of waiting for queue cycle)" },
    auto_approve_requests: { type: "boolean", default: false, category: "queue", description: "Automatically enqueue search immediately for requests created by non-admin users" },
    queue_batch_size: { type: "integer", default: 5, category: "queue", description: "Number of requests to process per queue run" },
    rate_limit_delay: { type: "integer", default: 2, category: "queue", description: "Seconds between API calls" },
    max_retries: { type: "integer", default: 10, category: "queue", description: "Maximum retry attempts before flagging for attention" },

    # Retry Settings
    retry_base_delay_hours: { type: "integer", default: 24, category: "queue", description: "Base delay in hours before retrying not_found requests" },
    retry_max_delay_days: { type: "integer", default: 7, category: "queue", description: "Maximum delay in days between retries" },

    # Open Library
    open_library_enabled: { type: "boolean", default: true, category: "open_library", description: "Enable Open Library as a metadata provider" },
    open_library_search_limit: { type: "integer", default: 20, category: "open_library", description: "Maximum number of search results to return" },

    # Google Books
    google_books_enabled: { type: "boolean", default: true, category: "google_books", description: "Enable Google Books as a metadata provider" },
    google_books_api_key: { type: "string", default: "", category: "google_books", description: "Optional Google Books API key. Leave blank to use anonymous public access; add a key for dedicated quota and more reliable requests." },
    google_books_search_limit: { type: "integer", default: 20, category: "google_books", description: "Maximum number of Google Books search results to return" },

    # Health Monitoring
    health_check_interval: { type: "integer", default: 300, category: "health", description: "Seconds between system health checks (default: 5 minutes)" },

    # Auto-Selection
    auto_select_enabled: { type: "boolean", default: false, category: "auto_select", description: "Automatically select the best search result without admin intervention" },
    auto_select_min_seeders: { type: "integer", default: 1, category: "auto_select", description: "Minimum seeders required for auto-selection (torrent only)" },
    auto_select_confidence_threshold: { type: "integer", default: 90, category: "auto_select", description: "Minimum confidence score (0-100) for auto-selection" },

    # Format Preferences
    ebook_approved_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated ebook formats that may be auto-selected (leave blank to allow any detected format)" },
    ebook_rejected_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated ebook formats that should never be auto-selected" },
    ebook_preferred_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated ebook formats in preference order, from best to worst" },
    audiobook_approved_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated audiobook formats that may be auto-selected (leave blank to allow any detected format)" },
    audiobook_rejected_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated audiobook formats that should never be auto-selected" },
    audiobook_preferred_formats: { type: "json", default: "[]", category: "format_preferences", description: "Comma-separated audiobook formats in preference order, from best to worst" },
    audiobook_prefer_single_file: { type: "boolean", default: false, category: "format_preferences", description: "Prefer single-file audiobook releases (for example .m4b) over chapter-split releases when detected" },
    audiobook_prefer_higher_bitrate: { type: "boolean", default: false, category: "format_preferences", description: "Prefer higher bitrate audiobook releases when the bitrate can be inferred from the title" },

    # Language Settings
    default_language: { type: "string", default: "en", category: "language", description: "Default language for new requests" },
    enabled_languages: { type: "json", default: '["en"]', category: "language", description: "Languages available for selection when creating requests" },
    min_match_confidence: { type: "integer", default: 50, category: "language", description: "Minimum confidence score (0-100) to display a search result" },

    # Updates
    github_repo: { type: "string", default: "Pedro-Revez-Silva/shelfarr", category: "updates", description: "GitHub repository for update notifications" },

    # Security
    auth_disabled: { type: "boolean", default: false, category: "security", description: "Disable password authentication (username-only login for trusted networks). Can also be set via DISABLE_AUTH env var." },
    session_max_age_days: { type: "integer", default: 30, category: "security", description: "Maximum session age in days before requiring re-login" },
    login_lockout_threshold: { type: "integer", default: 5, category: "security", description: "Failed login attempts before temporary lockout" },
    login_lockout_duration_minutes: { type: "integer", default: 15, category: "security", description: "Duration of login lockout in minutes" },
    api_token: { type: "string", category: "security", default: SecureRandom.base58(32), description: "Authentication token for the API" },
    allow_user_uploads: { type: "boolean", default: false, category: "security", description: "Allow non-admin users to upload book files directly" },

    # Anna's Archive
    anna_archive_enabled: { type: "boolean", default: false, category: "anna_archive", description: "Enable Anna's Archive as an additional search source for ebooks" },
    anna_archive_url: { type: "string", default: "https://annas-archive.se", category: "anna_archive", description: "Anna's Archive base URLs to try. Shelfarr uses the first reachable URL." },
    anna_archive_api_key: { type: "string", default: "", category: "anna_archive", description: "Member API key from Anna's Archive (requires donation)" },
    flaresolverr_url: { type: "string", default: "", category: "anna_archive", description: "FlareSolverr URL for bypassing DDoS protection (e.g., http://flaresolverr:8191)" },

    # Z-Library
    zlibrary_enabled: { type: "boolean", default: false, category: "zlibrary", description: "Enable the unofficial Z-Library fallback for ebook search and direct download. This integration may break if the service changes." },
    zlibrary_url: { type: "string", default: DEFAULT_ZLIBRARY_URLS, category: "zlibrary", description: "Z-Library base URLs to try. Shelfarr uses the first URL that accepts your login." },
    zlibrary_email: { type: "string", default: "", category: "zlibrary", description: "Z-Library account email used for login" },
    zlibrary_password: { type: "string", default: "", category: "zlibrary", description: "Z-Library account password used for login" },

    # LibriVox
    librivox_enabled: { type: "boolean", default: false, category: "librivox", description: "Enable LibriVox as a free public-domain audiobook source" },
    librivox_url: { type: "string", default: "https://librivox.org", category: "librivox", description: "LibriVox base URL" },
    librivox_search_limit: { type: "integer", default: 20, category: "librivox", description: "Maximum number of LibriVox audiobook results to return" },

    # Project Gutenberg
    gutenberg_enabled: { type: "boolean", default: false, category: "gutenberg", description: "Enable Project Gutenberg as a free public-domain ebook source" },
    gutenberg_url: { type: "string", default: "https://www.gutenberg.org", category: "gutenberg", description: "Project Gutenberg OPDS catalog base URL" },
    gutenberg_search_limit: { type: "integer", default: 10, category: "gutenberg", description: "Maximum number of Project Gutenberg ebook results to return" },

    # Hardcover Integration
    hardcover_enabled: { type: "boolean", default: true, category: "hardcover", description: "Enable Hardcover as a metadata provider when an API token is configured" },
    hardcover_api_token: { type: "string", default: "", category: "hardcover", description: "API token from Hardcover account settings (hardcover.app/account/api)" },
    metadata_source: { type: "string", default: "auto", category: "hardcover", description: "Legacy metadata source selector. Auto uses all enabled providers; selecting a provider restricts metadata search to that provider." },
    metadata_provider_priority: { type: "string", default: "hardcover,openlibrary,google_books", category: "hardcover", description: "Comma-separated metadata provider priority used when merging duplicate search results." },
    hardcover_search_limit: { type: "integer", default: 10, category: "hardcover", description: "Maximum number of search results from Hardcover" },

    # Webhook Notifications
    webhook_enabled: { type: "boolean", default: false, category: "webhook", description: "Send outbound webhook notifications for request lifecycle events" },
    webhook_url: { type: "string", default: "", category: "webhook", description: "Webhook endpoint URL. Shelfarr sends a JSON payload for each enabled event." },
    webhook_token: { type: "string", default: "", category: "webhook", description: "Optional Bearer token for webhook authentication" },
    webhook_events: { type: "string", default: "request_created,request_completed,request_failed,request_attention", category: "webhook", description: "Comma-separated webhook events to send" },
    webhook_topic: { type: "string", default: "", category: "webhook", description: "Optional topic field included in webhook JSON payload (required by ntfy when posting to the server base URL)" },

    # Discord Notifications
    discord_enabled: { type: "boolean", default: false, category: "discord", description: "Send native Discord webhook notifications for request lifecycle events" },
    discord_webhook_url: { type: "string", default: "", category: "discord", description: "Incoming Discord webhook URL for the channel that should receive notifications" },
    discord_events: { type: "string", default: "request_created,request_completed,request_failed,request_attention", category: "discord", description: "Comma-separated Discord notification events to send" },

    # Telegram Bot
    telegram_enabled: { type: "boolean", default: false, category: "telegram", description: "Enable the Telegram command integration" },
    telegram_update_mode: { type: "string", default: "polling", category: "telegram", description: "How Shelfarr receives Telegram updates. Polling works for local installs; webhook is optional for public HTTPS deployments." },
    telegram_bot_token: { type: "string", default: "", category: "telegram", description: "Bot token from BotFather. Required before accepting Telegram commands." },
    telegram_bot_username: { type: "string", default: "", category: "telegram", description: "Bot username without @. Commands addressed to other bots are ignored." },
    telegram_webhook_secret: { type: "string", default: "", category: "telegram", description: "Telegram webhook secret checked against X-Telegram-Bot-Api-Secret-Token" },
    telegram_allowed_chat_ids: { type: "string", default: "", category: "telegram", description: "Manual fallback allowlist for Telegram group chat IDs. Prefer approving groups with the pairing code below." },
    telegram_request_username: { type: "string", default: "", category: "telegram", description: "Shelfarr username used as the owner for Telegram group requests. Defaults to the first admin." },
    telegram_notification_events: { type: "string", default: "request_completed,request_failed,request_attention", category: "telegram", description: "Comma-separated request lifecycle events sent back to the authorized Telegram group that created the request" },

    # OIDC/SSO Authentication
    oidc_enabled: { type: "boolean", default: false, category: "oidc", description: "Enable OpenID Connect (OIDC) single sign-on authentication" },
    oidc_auto_redirect: { type: "boolean", default: false, category: "oidc", description: "Automatically start OIDC sign-in for unauthenticated users. Use /session/new?local=1 to access the local login form." },
    oidc_provider_name: { type: "string", default: "SSO", category: "oidc", description: "Display name for the OIDC provider (shown on login button)" },
    oidc_issuer: { type: "string", default: "", category: "oidc", description: "OIDC issuer URL (e.g., https://auth.example.com/realms/master)" },
    oidc_client_id: { type: "string", default: "", category: "oidc", description: "OIDC client ID from your identity provider" },
    oidc_client_secret: { type: "string", default: "", category: "oidc", description: "OIDC client secret from your identity provider" },
    oidc_scopes: { type: "string", default: "openid profile email", category: "oidc", description: "OIDC scopes to request (space-separated)" },
    oidc_link_existing_users: { type: "boolean", default: false, category: "oidc", description: "When enabled, OIDC sign-in will link an unlinked local user whose username matches the OIDC preferred username or email prefix." },
    oidc_auto_create_users: { type: "boolean", default: false, category: "oidc", description: "Automatically create new users on first OIDC login" },
    oidc_default_role: { type: "string", default: "user", category: "oidc", description: "Default role for auto-created OIDC users (user or admin)" }
  }.freeze

  CATEGORIES = {
    "indexer" => "Indexer",
    "download" => "Download Settings",
    "audiobookshelf" => "Library Platform",
    "anna_archive" => "Anna's Archive",
    "zlibrary" => "Z-Library",
    "gutenberg" => "Project Gutenberg",
    "librivox" => "LibriVox",
    "hardcover" => "Hardcover",
    "google_books" => "Google Books",
    "paths" => "Output Paths",
    "queue" => "Queue Settings",
    "open_library" => "Open Library",
    "health" => "Health Monitoring",
    "auto_select" => "Auto-Selection",
    "format_preferences" => "Format Preferences",
    "language" => "Language & Matching",
    "updates" => "Updates",
    "security" => "Security",
    "webhook" => "Webhook Notifications",
    "discord" => "Discord Notifications",
    "telegram" => "Telegram Bot",
    "oidc" => "OIDC/SSO Authentication"
  }.freeze

  LABELS = {
    library_platform: "Active Library Platform",
    audiobookshelf_url: "Audiobookshelf URL",
    audiobookshelf_api_key: "Audiobookshelf API Key",
    bookorbit_url: "BookOrbit URL",
    bookorbit_username: "BookOrbit Username",
    bookorbit_password: "BookOrbit Password",
    audiobookshelf_audiobook_library_id: "Audiobook Library",
    audiobookshelf_ebook_library_id: "Ebook Library",
    audiobookshelf_library_sync_interval: "Library Sync Interval"
  }.freeze

  class << self
    def label_for(key)
      LABELS.fetch(key.to_sym, key.to_s.titleize)
    end

    # Primary getter with default fallback
    def get(key, default: nil)
      key = key.to_sym
      return preferred_download_types if key == :preferred_download_types

      value = raw_setting_value(key)
      return value unless value.nil?

      definition = DEFINITIONS[key]
      definition ? definition[:default] : default
    end

    # Primary setter
    def set(key, value)
      key = key.to_sym
      definition = DEFINITIONS[key]

      raise ArgumentError, "Unknown setting: #{key}" unless definition

      setting = Setting.find_or_initialize_by(key: key.to_s)
      setting.value_type = definition[:type]
      setting.category = definition[:category]
      setting.description = definition[:description]
      setting.typed_value = value
      setting.save!

      setting.typed_value
    end

    # Bulk getter for a category
    def for_category(category)
      DEFINITIONS.select { |_, v| v[:category] == category }.keys.each_with_object({}) do |key, hash|
        hash[key] = get(key)
      end
    end

    # Check if a setting is configured (non-empty for strings)
    def configured?(key)
      value = get(key)
      return false if value.nil?
      return value.present? if value.is_a?(String)
      true
    end

    # Get all settings organized by category
    def all_by_category
      DEFINITIONS.keys.group_by { |key| DEFINITIONS[key][:category] }.transform_values do |keys|
        keys.each_with_object({}) do |key, hash|
          hash[key] = {
            value: get(key),
            definition: DEFINITIONS[key]
          }
        end
      end
    end

    # Initialize all settings with defaults (run on first setup)
    def seed_defaults!
      DEFINITIONS.each do |key, definition|
        next if Setting.exists?(key: key.to_s)

        Setting.create!(
          key: key.to_s,
          value: definition[:default].to_s,
          value_type: definition[:type],
          category: definition[:category],
          description: definition[:description]
        )
      end
    end

    # Check if integrations are configured
    def prowlarr_configured?
      configured?(:prowlarr_url) && configured?(:prowlarr_api_key)
    end

    def jackett_configured?
      configured?(:jackett_url) && configured?(:jackett_api_key)
    end

    def newznab_configured?
      configured?(:newznab_url) && configured?(:newznab_api_key)
    end

    def active_indexer_provider
      provider = get(:indexer_provider).to_s.strip
      return provider if %w[none prowlarr jackett newznab].include?(provider)

      return "prowlarr" if prowlarr_configured?

      "none"
    end

    def active_indexer_configured?
      case active_indexer_provider
      when "prowlarr"
        prowlarr_configured?
      when "jackett"
        jackett_configured?
      when "newznab"
        newznab_configured?
      else
        false
      end
    end

    def active_indexer_search_scope
      scope = get(:indexer_search_scope).to_s.strip.downcase
      INDEXER_SEARCH_SCOPES.include?(scope) ? scope : "broad"
    end

    def broad_indexer_search_scope?
      active_indexer_search_scope == "broad"
    end

    def unrestricted_indexer_search_scope?
      active_indexer_search_scope == "unrestricted"
    end

    def indexer_category_ids_for(book_type)
      return [] if unrestricted_indexer_search_scope?

      ids = if active_indexer_search_scope == "custom"
        custom_indexer_category_ids_for(book_type)
      else
        []
      end

      ids.presence || default_indexer_category_ids_for(book_type)
    end

    def download_client_configured?
      DownloadClient.enabled.exists?
    end

    def audiobookshelf_configured?
      library_platform_configured?
    end

    def library_platform_configured?
      if bookorbit_library_platform?
        bookorbit_configured?
      else
        audiobookshelf_credentials_configured?
      end
    end

    def audiobookshelf_credentials_configured?
      configured?(:audiobookshelf_url) && configured?(:audiobookshelf_api_key)
    end

    def bookorbit_configured?
      configured?(:bookorbit_url) && configured?(:bookorbit_username) && configured?(:bookorbit_password)
    end

    def active_library_platform
      platform = get(:library_platform).to_s.strip.downcase
      LIBRARY_PLATFORMS.include?(platform) ? platform : "audiobookshelf"
    end

    def bookorbit_library_platform?
      active_library_platform == "bookorbit"
    end

    def anna_archive_configured?
      get(:anna_archive_enabled, default: false) && configured?(:anna_archive_api_key)
    end

    def zlibrary_configured?
      get(:zlibrary_enabled, default: false) &&
        configured?(:zlibrary_url) &&
        configured?(:zlibrary_email) &&
        configured?(:zlibrary_password)
    end

    def librivox_configured?
      get(:librivox_enabled, default: false) && configured?(:librivox_url)
    end

    def gutenberg_configured?
      get(:gutenberg_enabled, default: false) && configured?(:gutenberg_url)
    end

    def flaresolverr_configured?
      configured?(:flaresolverr_url)
    end

    def oidc_configured?
      get(:oidc_enabled, default: false) &&
        configured?(:oidc_issuer) &&
        configured?(:oidc_client_id) &&
        configured?(:oidc_client_secret)
    end

    def oidc_auto_redirect?
      oidc_configured? &&
        !auth_disabled? &&
        get(:oidc_auto_redirect, default: false)
    end

    def hardcover_configured?
      configured?(:hardcover_api_token)
    end

    def metadata_provider_priority
      providers = normalize_metadata_providers(get(:metadata_provider_priority))
      providers = default_metadata_provider_priority if providers.empty?

      providers + (default_metadata_provider_priority - providers)
    end

    def enabled_metadata_providers
      legacy_source = get(:metadata_source, default: "auto").to_s.strip
      if metadata_provider_keys.include?(legacy_source) && legacy_source != "auto"
        return provider_enabled?(legacy_source) ? [ legacy_source ] : []
      end

      metadata_provider_priority.select { |provider| provider_enabled?(provider) }
    end

    def api_token
      setting = Setting.find_by(key: "api_token")
      return nil unless setting

      setting.typed_value.presence
    end

    def api_token_configured?
      api_token.present?
    end

    def auth_disabled?
      ENV["DISABLE_AUTH"]&.downcase == "true" || get(:auth_disabled, default: false)
    end

    def user_uploads_allowed?
      get(:allow_user_uploads, default: false)
    end

    def auto_approve_requests?
      get(:auto_approve_requests, default: false)
    end

    def preferred_download_types
      stored_preferred_types = Setting.find_by(key: "preferred_download_types")&.typed_value
      ordered_types = normalize_download_types(stored_preferred_types)

      if ordered_types.empty?
        legacy_type = normalize_download_types(Setting.find_by(key: "preferred_download_type")&.typed_value).first
        ordered_types = legacy_type ? [ legacy_type ] : []
      end

      ordered_types + (DOWNLOAD_TYPES - ordered_types)
    end

    def download_type_options
      preferred_download_types.map do |type|
        DOWNLOAD_TYPE_OPTIONS.fetch(type)
          .merge(value: type)
      end
    end

    def indexer_search_scope_options
      INDEXER_SEARCH_SCOPES.map do |scope|
        INDEXER_SEARCH_SCOPE_OPTIONS.fetch(scope)
          .merge(value: scope)
      end
    end

    def format_preferences_for(book_type)
      type = book_type.to_s
      return default_format_preferences unless %w[audiobook ebook].include?(type)

      {
        approved_formats: normalized_list_setting("#{type}_approved_formats"),
        rejected_formats: normalized_list_setting("#{type}_rejected_formats"),
        preferred_formats: normalized_list_setting("#{type}_preferred_formats"),
        prefer_single_file: type == "audiobook" && get(:audiobook_prefer_single_file, default: false),
        prefer_higher_bitrate: type == "audiobook" && get(:audiobook_prefer_higher_bitrate, default: false)
      }
    end

    private

    def provider_enabled?(provider)
      case provider.to_s
      when "hardcover"
        get(:hardcover_enabled, default: true) && hardcover_configured?
      when "google_books"
        get(:google_books_enabled, default: true)
      when "openlibrary"
        get(:open_library_enabled, default: true)
      else
        false
      end
    end

    def normalize_metadata_providers(value)
      Array(value).flat_map { |entry| entry.to_s.split(/[,\s]+/) }.filter_map do |provider|
        normalized = provider.strip.downcase
        normalized if metadata_provider_keys.include?(normalized)
      end.uniq
    end

    def default_metadata_provider_priority
      %w[hardcover openlibrary google_books]
    end

    def metadata_provider_keys
      %w[hardcover openlibrary google_books]
    end

    def raw_setting_value(key)
      setting = Setting.find_by(key: key.to_s)
      return setting.typed_value if setting

      DEFINITIONS[key.to_sym]&.dig(:default)
    end

    def normalize_download_types(values)
      Array(values).filter_map do |value|
        normalized = value.to_s.strip.downcase
        normalized if DOWNLOAD_TYPES.include?(normalized)
      end.uniq
    end

    def custom_indexer_category_ids_for(book_type)
      key = case book_type&.to_sym
      when :audiobook
        :indexer_custom_audiobook_categories
      when :ebook
        :indexer_custom_ebook_categories
      else
        nil
      end

      if key
        normalize_category_ids(get(key))
      else
        (normalize_category_ids(get(:indexer_custom_audiobook_categories)) +
          normalize_category_ids(get(:indexer_custom_ebook_categories))).uniq
      end
    end

    def default_indexer_category_ids_for(book_type)
      case book_type&.to_sym
      when :audiobook
        DEFAULT_INDEXER_CATEGORY_IDS[:audiobook]
      when :ebook
        DEFAULT_INDEXER_CATEGORY_IDS[:ebook]
      else
        DEFAULT_INDEXER_CATEGORY_IDS[:all_books]
      end
    end

    def normalize_category_ids(values)
      Array(values).flat_map { |value| value.to_s.split(/[,\s]+/) }.filter_map do |value|
        Integer(value.strip, exception: false)
      end.reject(&:zero?).uniq
    end

    def normalized_list_setting(key)
      Array(get(key)).filter_map do |value|
        normalized = value.to_s.strip.downcase
        normalized.presence
      end.uniq
    end

    def default_format_preferences
      {
        approved_formats: [],
        rejected_formats: [],
        preferred_formats: [],
        prefer_single_file: false,
        prefer_higher_bitrate: false
      }
    end
  end
end
