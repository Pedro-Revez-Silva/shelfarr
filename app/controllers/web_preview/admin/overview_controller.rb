# frozen_string_literal: true

class WebPreview::Admin::OverviewController < WebPreview::Admin::BaseController
  FIXES = {
    "indexer" => { category: "sources", group: "indexer", label: "Indexer settings" },
    "download_client" => { category: "downloads", group: "download_clients", label: "Download clients" },
    "download_paths" => { category: "downloads", group: "path_mapping", label: "Path mapping" },
    "output_paths" => { category: "library", group: "folders", label: "Folder settings" },
    "audiobookshelf" => { category: "library", group: "library_platform", label: "Library platform settings" },
    "hardcover" => { category: "sources", group: "hardcover", label: "Hardcover settings" }
  }.freeze
  LABELS = { "audiobookshelf" => "Library platform" }.freeze
  DEFAULT_REPOSITORY = "Pedro-Revez-Silva/shelfarr"

  def show
    render json: overview
  end

  def health_check
    HealthCheckJob.perform_later
    render json: { **overview, outcome: success("Health check started. Results will appear shortly.") }
  rescue => e
    Rails.logger.error "[WebPreview::Admin::OverviewController] Health check failed: #{e.class}"
    render json: { **overview, outcome: failure("Health check failed. Check logs for details.") }
  end

  def update_check
    result = UpdateCheckerService.check(force: true)
    render json: { **overview(result), outcome: update_outcome(result) }
  end

  private

  def overview(update_check = UpdateCheckerService.cached_result)
    health = SystemHealth.all.index_by(&:service)
    {
      account: web_preview_account_id,
      counts: {
        users: User.active.count,
        books: Book.count,
        active_requests: Request.active.count,
        attention_requests: Request.needs_attention.count
      },
      services: SystemHealth::SERVICES.map { |service| service_json(service, health[service]) },
      release: release_json(update_check),
      pending: pending_screens,
      setup: { pending: SetupWizard.pending?, completed: SetupWizard.completed? }
    }
  end

  def pending_screens
    [
      [ "Custom acquisition providers", admin_acquisition_providers_path ],
      [ "Users", admin_users_path ],
      [ "Audible backup", admin_owned_library_connections_path ],
      [ "Activity log", admin_activity_logs_path ]
    ].map { |label, url| { label: label, url: url } }
  end

  def service_json(service, health)
    {
      service: service,
      label: LABELS.fetch(service) { service.humanize },
      status: health&.status,
      message: service == WebPreview::DownloadManagement::HEALTH_SERVICE ? WebPreview::DownloadManagement.health_sentence(health&.status) : WebPreview::SecretRedaction.call(health&.message.presence),
      checked_at: health&.last_check_at&.iso8601,
      fix: FIXES[service]
    }.compact.merge(status: health&.status, checked_at: health&.last_check_at&.iso8601)
  end

  def release_json(check)
    channel = Shelfarr::ReleaseChannel.current
    repository = SettingsService.get(:github_repo).presence || DEFAULT_REPOSITORY
    {
      build: Consumer::ServerInfo.server_version,
      channel: channel.label,
      beta: channel.beta?,
      series: channel.series.to_s,
      image: "ghcr.io/#{repository.downcase}:#{channel.image_channel_tag}",
      image_tag: channel.image_channel_tag,
      guide_url: "https://github.com/#{repository}/blob/main/docs/releases.md",
      latest: latest_json(check)
    }
  end

  def latest_json(check)
    return { state: "unchecked" } if check.nil?
    return { state: "available", version: check.latest_version, release_url: Consumer::SafeLink.call(check.release_url) }.compact if check.update_available?
    return { state: "current", version: check.latest_version } if check.latest_version.present?

    { state: "failed", message: WebPreview::SecretRedaction.call(check.latest_message.presence) }.compact
  end

  def update_outcome(check)
    if check.update_available?
      success("Update available: #{check.latest_version}")
    elsif check.latest_version.blank?
      failure("Couldn't check for updates: #{check.latest_message}")
    else
      success("You're running the latest version (#{check.current_version})")
    end
  end
end
