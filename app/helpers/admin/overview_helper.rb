# frozen_string_literal: true

module Admin::OverviewHelper
  HealthFix = Data.define(:label, :path)

  HEALTH_LABELS = { "audiobookshelf" => "Library platform" }.freeze
  ISSUE_STATUSES = %w[down degraded].freeze

  def health_service_label(service)
    HEALTH_LABELS.fetch(service) { service.humanize }
  end

  def health_issue?(health)
    health.present? && ISSUE_STATUSES.include?(health.status)
  end

  def health_fix(service)
    case service
    when "indexer" then HealthFix.new("Indexer settings", admin_settings_path(anchor: settings_section_id("indexer")))
    when "download_client" then HealthFix.new("Download clients", admin_download_clients_path)
    when "download_paths", "output_paths" then HealthFix.new("Folder settings", admin_settings_path(anchor: settings_section_id("paths")))
    when "audiobookshelf" then HealthFix.new("Library platform settings", admin_settings_path(anchor: settings_section_id("audiobookshelf")))
    when "hardcover" then HealthFix.new("Hardcover settings", admin_settings_path(anchor: settings_section_id("hardcover")))
    end
  end
end
