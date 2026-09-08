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

  def settings_field_description(key, data)
    description = data[:definition][:description]
    key.to_s.end_with?("_path_template", "_filename_template") ? description.split(" Variables include").first : description
  end

  def settings_field_save_hint(key)
    SettingsService.manual_save_setting_key?(key) ? "Requires Save All" : "Saves automatically"
  end
end
