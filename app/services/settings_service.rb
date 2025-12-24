class SettingsService
  # Define all expected settings with their defaults and types
  DEFINITIONS = {
    # Prowlarr Integration
    prowlarr_url: { type: "string", default: "", category: "prowlarr", description: "Base URL for Prowlarr instance (e.g., http://localhost:9696)" },
    prowlarr_api_key: { type: "string", default: "", category: "prowlarr", description: "API key from Prowlarr Settings > General" },

    # Download Settings (clients are now managed separately via Admin > Download Clients)
    preferred_download_type: { type: "string", default: "torrent", category: "download", description: "Preferred download type when both available (torrent or usenet)" },
    download_check_interval: { type: "integer", default: 60, category: "download", description: "Seconds between download status checks" },

    # Audiobookshelf Integration
    audiobookshelf_url: { type: "string", default: "", category: "audiobookshelf", description: "Base URL for Audiobookshelf (e.g., http://localhost:13378)" },
    audiobookshelf_api_key: { type: "string", default: "", category: "audiobookshelf", description: "API token from Audiobookshelf user settings" },
    audiobookshelf_library_id: { type: "string", default: "", category: "audiobookshelf", description: "Target library ID for imported content" },

    # Output Paths
    audiobook_output_path: { type: "string", default: "/audiobooks", category: "paths", description: "Directory for completed audiobooks" },
    ebook_output_path: { type: "string", default: "/ebooks", category: "paths", description: "Directory for completed ebooks" },
    download_remote_path: { type: "string", default: "", category: "paths", description: "Download client path (host path, e.g., /mnt/media/Torrents/Completed)" },
    download_local_path: { type: "string", default: "/downloads", category: "paths", description: "Container path for downloads (e.g., /downloads)" },

    # Queue Settings
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

    # Updates
    github_repo: { type: "string", default: "Pedro-Revez-Silva/shelfarr", category: "updates", description: "GitHub repository for update notifications" },

    # Security
    session_max_age_days: { type: "integer", default: 30, category: "security", description: "Maximum session age in days before requiring re-login" },
    login_lockout_threshold: { type: "integer", default: 5, category: "security", description: "Failed login attempts before temporary lockout" },
    login_lockout_duration_minutes: { type: "integer", default: 15, category: "security", description: "Duration of login lockout in minutes" }
  }.freeze

  CATEGORIES = {
    "prowlarr" => "Prowlarr",
    "download" => "Download Settings",
    "audiobookshelf" => "Audiobookshelf",
    "paths" => "Output Paths",
    "queue" => "Queue Settings",
    "open_library" => "Open Library",
    "health" => "Health Monitoring",
    "auto_select" => "Auto-Selection",
    "updates" => "Updates",
    "security" => "Security"
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
  end
end
