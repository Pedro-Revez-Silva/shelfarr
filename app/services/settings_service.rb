class SettingsService
  # Define all expected settings with their defaults and types
  DEFINITIONS = {
    # Prowlarr Integration
    prowlarr_url: { type: "string", default: "", category: "prowlarr", description: "Base URL for Prowlarr instance (e.g., http://localhost:9696)" },
    prowlarr_api_key: { type: "string", default: "", category: "prowlarr", description: "API key from Prowlarr Settings > General" },
    prowlarr_tags: { type: "string", default: "", category: "prowlarr", description: "Comma-separated tag IDs to filter indexers (leave empty for all indexers)" },

    # Download Settings (clients are now managed separately via Admin > Download Clients)
    preferred_download_type: { type: "string", default: "torrent", category: "download", description: "Preferred download type when both available (torrent or usenet)" },
    download_check_interval: { type: "integer", default: 60, category: "download", description: "Seconds between download status checks" },

    # Audiobookshelf Integration
    audiobookshelf_url: { type: "string", default: "", category: "audiobookshelf", description: "Base URL for Audiobookshelf (e.g., http://localhost:13378)" },
    audiobookshelf_api_key: { type: "string", default: "", category: "audiobookshelf", description: "API token from Audiobookshelf user settings" },
    audiobookshelf_audiobook_library_id: { type: "string", default: "", category: "audiobookshelf", description: "Library ID for audiobooks" },
    audiobookshelf_ebook_library_id: { type: "string", default: "", category: "audiobookshelf", description: "Library ID for ebooks" },

    # Output Paths
    audiobook_output_path: { type: "string", default: "/audiobooks", category: "paths", description: "Directory for completed audiobooks" },
    ebook_output_path: { type: "string", default: "/ebooks", category: "paths", description: "Directory for completed ebooks" },
    audiobook_path_template: { type: "string", default: "{author}/{title}", category: "paths", description: "Folder structure for audiobooks. Variables: {author}, {title}, {year}, {publisher}, {language}" },
    ebook_path_template: { type: "string", default: "{author}/{title}", category: "paths", description: "Folder structure for ebooks. Variables: {author}, {title}, {year}, {publisher}, {language}" },
    audiobook_filename_template: { type: "string", default: "{author} - {title}", category: "paths", description: "Filename for audiobooks (extension added automatically). Variables: {author}, {title}, {year}" },
    ebook_filename_template: { type: "string", default: "{author} - {title}", category: "paths", description: "Filename for ebooks (extension added automatically). Variables: {author}, {title}, {year}" },
    download_remote_path: { type: "string", default: "", category: "paths", description: "Download client path (host path, e.g., /mnt/media/Torrents/Completed)" },
    download_local_path: { type: "string", default: "/downloads", category: "paths", description: "Container path for downloads (e.g., /downloads)" },

    # Queue Settings
    immediate_search_enabled: { type: "boolean", default: false, category: "queue", description: "Start searching immediately when a request is created (instead of waiting for queue cycle)" },
    queue_batch_size: { type: "integer", default: 5, category: "queue", description: "Number of requests to process per queue run" },
    rate_limit_delay: { type: "integer", default: 2, category: "queue", description: "Seconds between API calls" },
    max_retries: { type: "integer", default: 10, category: "queue", description: "Maximum retry attempts before flagging for attention" },

    # Retry Settings
    retry_base_delay_hours: { type: "integer", default: 24, category: "queue", description: "Base delay in hours before retrying not_found requests" },
    retry_max_delay_days: { type: "integer", default: 7, category: "queue", description: "Maximum delay in days between retries" },

    # Open Library
    open_library_search_limit: { type: "integer", default: 20, category: "open_library", description: "Maximum number of search results to return" },

    # Health Monitoring
    health_check_interval: { type: "integer", default: 300, category: "health", description: "Seconds between system health checks (default: 5 minutes)" },

    # Auto-Selection
    auto_select_enabled: { type: "boolean", default: false, category: "auto_select", description: "Automatically select the best search result without admin intervention" },
    auto_select_min_seeders: { type: "integer", default: 1, category: "auto_select", description: "Minimum seeders required for auto-selection (torrent only)" },
    auto_select_confidence_threshold: { type: "integer", default: 90, category: "auto_select", description: "Minimum confidence score (0-100) for auto-selection" },

    # Language Settings
    default_language: { type: "string", default: "en", category: "language", description: "Default language for new requests" },
    enabled_languages: { type: "json", default: '["en"]', category: "language", description: "Languages available for selection when creating requests" },
    min_match_confidence: { type: "integer", default: 50, category: "language", description: "Minimum confidence score (0-100) to display a search result" },

    # Updates
    github_repo: { type: "string", default: "Pedro-Revez-Silva/shelfarr", category: "updates", description: "GitHub repository for update notifications" },

    # Security
    session_max_age_days: { type: "integer", default: 30, category: "security", description: "Maximum session age in days before requiring re-login" },
    login_lockout_threshold: { type: "integer", default: 5, category: "security", description: "Failed login attempts before temporary lockout" },
    login_lockout_duration_minutes: { type: "integer", default: 15, category: "security", description: "Duration of login lockout in minutes" },

    # Anna's Archive
    anna_archive_enabled: { type: "boolean", default: false, category: "anna_archive", description: "Enable Anna's Archive as an additional search source for ebooks" },
    anna_archive_url: { type: "string", default: "https://annas-archive.se", category: "anna_archive", description: "Base URL for Anna's Archive (change if domain moves)" },
    anna_archive_api_key: { type: "string", default: "", category: "anna_archive", description: "Member API key from Anna's Archive (requires donation)" },
    flaresolverr_url: { type: "string", default: "", category: "anna_archive", description: "FlareSolverr URL for bypassing DDoS protection (e.g., http://flaresolverr:8191)" },

    # Hardcover Integration
    hardcover_api_token: { type: "string", default: "", category: "hardcover", description: "API token from Hardcover account settings (hardcover.app/account/api)" },
    metadata_source: { type: "string", default: "auto", category: "hardcover", description: "Primary metadata source: auto (Hardcover first, OpenLibrary fallback), hardcover, or openlibrary" },
    hardcover_search_limit: { type: "integer", default: 10, category: "hardcover", description: "Maximum number of search results from Hardcover" },

    # OIDC/SSO Authentication
    oidc_enabled: { type: "boolean", default: false, category: "oidc", description: "Enable OpenID Connect (OIDC) single sign-on authentication" },
    oidc_provider_name: { type: "string", default: "SSO", category: "oidc", description: "Display name for the OIDC provider (shown on login button)" },
    oidc_issuer: { type: "string", default: "", category: "oidc", description: "OIDC issuer URL (e.g., https://auth.example.com/realms/master)" },
    oidc_client_id: { type: "string", default: "", category: "oidc", description: "OIDC client ID from your identity provider" },
    oidc_client_secret: { type: "string", default: "", category: "oidc", description: "OIDC client secret from your identity provider" },
    oidc_scopes: { type: "string", default: "openid profile email", category: "oidc", description: "OIDC scopes to request (space-separated)" },
    oidc_auto_create_users: { type: "boolean", default: false, category: "oidc", description: "Automatically create new users on first OIDC login" },
    oidc_default_role: { type: "string", default: "user", category: "oidc", description: "Default role for auto-created OIDC users (user or admin)" }
  }.freeze

  CATEGORIES = {
    "prowlarr" => "Prowlarr",
    "download" => "Download Settings",
    "audiobookshelf" => "Audiobookshelf",
    "anna_archive" => "Anna's Archive",
    "hardcover" => "Hardcover",
    "paths" => "Output Paths",
    "queue" => "Queue Settings",
    "open_library" => "Open Library",
    "health" => "Health Monitoring",
    "auto_select" => "Auto-Selection",
    "language" => "Language & Matching",
    "updates" => "Updates",
    "security" => "Security",
    "oidc" => "OIDC/SSO Authentication"
  }.freeze

  class << self
    # Primary getter with default fallback
    def get(key, default: nil)
      key = key.to_sym
      definition = DEFINITIONS[key]

      setting = Setting.find_by(key: key.to_s)

      if setting
        setting.typed_value
      elsif definition
        definition[:default]
      else
        default
      end
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

    def download_client_configured?
      DownloadClient.enabled.exists?
    end

    def audiobookshelf_configured?
      configured?(:audiobookshelf_url) && configured?(:audiobookshelf_api_key)
    end

    def anna_archive_configured?
      get(:anna_archive_enabled, default: false) && configured?(:anna_archive_api_key)
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

    def hardcover_configured?
      configured?(:hardcover_api_token)
    end
  end
end
