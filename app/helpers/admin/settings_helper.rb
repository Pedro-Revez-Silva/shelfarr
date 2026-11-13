module Admin::SettingsHelper
  COLLAPSIBLE_SETTINGS_SOURCES = %w[anna_archive zlibrary gutenberg librivox ebooks_com].freeze
  ADVANCED_DOWNLOAD_SETTINGS = %i[
    download_check_interval download_enqueue_timeout_minutes post_processing_source_path_retries
    split_audiobook_bundle_imports remove_completed_usenet_downloads precreate_download_archives
  ].freeze
  LIBRARY_CREDENTIAL_PROVIDERS = {
    "audiobookshelf_url" => "audiobookshelf", "audiobookshelf_api_key" => "audiobookshelf",
    "bookorbit_url" => "bookorbit", "bookorbit_username" => "bookorbit", "bookorbit_password" => "bookorbit",
    "grimmory_url" => "grimmory", "grimmory_username" => "grimmory", "grimmory_password" => "grimmory"
  }.freeze

  SETTINGS_TABS = {
    "search" => {
      label: "Search",
      summary: "Indexers, sources, languages and automatic selection",
      categories: %w[indexer anna_archive zlibrary gutenberg librivox ebooks_com language auto_select]
    },
    "downloads" => {
      label: "Downloads",
      summary: "Library folders, file handling and preferred formats",
      categories: %w[paths download format_preferences]
    },
    "integrations" => {
      label: "Integrations",
      summary: "Library platform, metadata providers and notifications",
      categories: %w[audiobookshelf hardcover google_books open_library comic_vine discord telegram]
    },
    "system" => {
      label: "Queue & System",
      summary: "Background work, health checks and update checks",
      categories: %w[queue health updates]
    },
    "security" => {
      label: "Security",
      summary: "Sign-in rules, single sign-on and webhooks",
      categories: %w[security oidc webhook]
    }
  }.freeze

  def settings_section_id(category)
    "settings-section-#{category}"
  end

  def settings_field_description(key, data)
    description = data[:definition][:description]
    key.to_s.end_with?("_path_template", "_filename_template") ? description.split(" Variables include").first : description
  end

  def settings_field_save_hint(key)
    SettingsService.manual_save_setting_key?(key) ? "Requires Save All" : "Saves automatically"
  end
end
