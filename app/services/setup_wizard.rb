# frozen_string_literal: true

class SetupWizard
  STEPS = %w[prowlarr qbittorrent folders audiobookshelf search].freeze
  STEP_LABELS = {
    "prowlarr" => "Prowlarr",
    "qbittorrent" => "qBittorrent",
    "folders" => "Folders",
    "audiobookshelf" => "Audiobookshelf",
    "search" => "Search"
  }.freeze

  Result = Struct.new(:success, :error, :notice, :alert, :stay, keyword_init: true) do
    def success?
      success
    end

    def stay?
      stay
    end
  end

  class << self
    def normalize_step(step)
      STEPS.include?(step.to_s) ? step.to_s : STEPS.first
    end

    def next_step(step)
      STEPS[STEPS.index(normalize_step(step)).to_i + 1] || STEPS.last
    end

    def previous_step(step)
      index = STEPS.index(normalize_step(step)).to_i
      STEPS[index - 1] if index.positive?
    end

    def pending?
      !completed? && !SettingsService.active_indexer_configured? && !DownloadClient.enabled.exists?
    end

    def completed?
      ActiveModel::Type::Boolean.new.cast(SettingsService.get(:setup_wizard_completed))
    end

    def complete!
      SettingsService.set(:setup_wizard_completed, true)
    end

    def restart!
      SettingsService.set(:setup_wizard_completed, false)
    end

    def save(step, params)
      case normalize_step(step)
      when "prowlarr" then save_prowlarr(params)
      when "qbittorrent" then save_qbittorrent(params)
      when "folders" then save_folders(params)
      when "audiobookshelf" then save_audiobookshelf(params)
      when "search" then save_search(params)
      end
    end

    def qbittorrent_client
      DownloadClient.qbittorrent.order(:priority, :id).first
    end

    # Overrides let a step check the values on its form before they are saved.
    def path_warnings(overrides = {})
      paths = saved_paths.merge(overrides.compact)
      [ qbittorrent_warning(paths), *audiobookshelf_warnings(paths) ].compact
    end

    def library_choices
      LibraryPlatformClient.reset_connections!
      [ LibraryPlatformClient.libraries, nil ]
    rescue LibraryPlatformClient::Error => e
      [ [], e.message ]
    end

    def suggested_remote_path(local_path)
      diagnostics = diagnostics_for
      return if diagnostics.nil? || visible_save_path?(diagnostics, local_path)

      mapping_save_path(diagnostics)
    end

    # Preselect the library whose folder holds the output path, as the path check expects.
    def suggested_library_id(libraries, output_path)
      library = Array(libraries).find do |item|
        item.folder_paths.to_a.any? { |folder| inside_path?(output_path, folder) }
      end
      library&.id
    end

    private

    def save_prowlarr(params)
      url = params[:url].to_s.strip
      api_key = params[:api_key].to_s.strip.presence || SettingsService.get(:prowlarr_api_key).to_s
      return failure("Enter the Prowlarr URL and API key.") if url.blank? || api_key.blank?
      return failure("Prowlarr connection failed.") unless ConnectionProbe.indexer(provider: "prowlarr", url: url, api_key: api_key)

      SettingsService.set(:indexer_provider, "prowlarr")
      SettingsService.set(:prowlarr_url, url)
      SettingsService.set(:prowlarr_api_key, api_key)
      IndexerClient.reset_all_connections!
      success(notice: "Prowlarr connected.")
    rescue IndexerClients::Base::AuthenticationError
      failure("Prowlarr rejected the API key. Copy it from Prowlarr under Settings > General.")
    rescue IndexerClients::Base::Error => e
      failure("Could not connect to Prowlarr: #{e.message}")
    end

    def save_qbittorrent(params)
      url = params[:url].to_s.strip
      return failure("Enter the qBittorrent URL.") if url.blank?

      existing = qbittorrent_client
      api_key = params[:api_key].to_s.strip
      username = params[:username].to_s.strip
      password = params[:password].to_s
      category = params[:category].to_s

      if api_key.present? && !valid_api_key?(api_key)
        return failure("qBittorrent API key must start with qbt_ and contain 28 characters after the prefix.")
      end
      return failure("Enter a username and password, or a qBittorrent API key.") unless credentials_present?(existing, username, password, api_key)

      # A new password switches a client that used an API key back to a login.
      password_login = api_key.blank? && password.present?
      probe_key = api_key.presence || (existing&.api_key unless password_login)
      probe_password = password.presence || existing&.password
      probe_username = username.presence || existing&.username
      unless ConnectionProbe.qbittorrent(url: url, username: probe_username, password: probe_password, api_key: probe_key, category: category)
        return failure("qBittorrent connection failed.")
      end

      persist_qbittorrent!(existing, url: url, username: probe_username, password: password, api_key: api_key, category: category,
        clear_api_key: password_login)
      start_download_monitor
      success(notice: "qBittorrent connected.")
    rescue DownloadClients::Base::AuthenticationError
      failure("qBittorrent rejected the login. Check the username and password, or the API key.")
    rescue DownloadClients::Base::Error => e
      failure("Could not connect to qBittorrent: #{e.message}")
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    def save_folders(params)
      local = normalize_path(params[:download_local_path]).to_s
      remote = normalize_path(params[:download_remote_path]).to_s
      # qBittorrent is already writing inside this container, so a host-path map would be wrong.
      remote = "" if container_save_path?(local)

      SettingsService.set(:audiobook_output_path, normalize_path(params[:audiobook_output_path]).to_s)
      SettingsService.set(:ebook_output_path, normalize_path(params[:ebook_output_path]).to_s)
      SettingsService.set(:download_local_path, local)
      SettingsService.set(:download_remote_path, remote)
      success(notice: "Folders saved.", alert: path_warnings.presence&.join(" "))
    end

    def save_audiobookshelf(params)
      if params[:phase].to_s == "libraries"
        SettingsService.set(:library_platform, "audiobookshelf")
        SettingsService.set(:audiobookshelf_audiobook_library_id, params[:audiobook_library_id].to_s)
        SettingsService.set(:audiobookshelf_ebook_library_id, params[:ebook_library_id].to_s)
        return success(notice: "Audiobookshelf libraries saved.")
      end

      url = params[:url].to_s.strip
      api_key = params[:api_key].to_s.strip.presence || SettingsService.get(:audiobookshelf_api_key).to_s
      return failure("Enter the Audiobookshelf URL and API token.") if url.blank? || api_key.blank?
      unless ConnectionProbe.audiobookshelf(url: url, api_key: api_key)
        return failure("Audiobookshelf has no libraries yet. Create one in Audiobookshelf, then try again, or skip this step.")
      end

      SettingsService.set(:library_platform, "audiobookshelf")
      SettingsService.set(:audiobookshelf_url, url)
      SettingsService.set(:audiobookshelf_api_key, api_key)
      LibraryPlatformClient.reset_connections!
      success(notice: "Audiobookshelf connected. Choose the libraries Shelfarr should scan.", stay: true)
    rescue AudiobookshelfClient::AuthenticationError
      failure("Audiobookshelf rejected the API token. Copy it from your user in Audiobookshelf under Settings > Users.")
    rescue AudiobookshelfClient::Error => e
      failure("Could not connect to Audiobookshelf: #{e.message}")
    end

    def save_search(params)
      immediate = ActiveModel::Type::Boolean.new.cast(params.fetch(:immediate_search_enabled, "1"))
      auto_select = ActiveModel::Type::Boolean.new.cast(params.fetch(:auto_select_enabled, "0"))
      SettingsService.set(:immediate_search_enabled, immediate)
      SettingsService.set(:auto_select_enabled, auto_select)
      complete!
      success(notice: "Setup complete.")
    end

    # One download client: a later pass updates the qBittorrent row instead of adding another.
    def persist_qbittorrent!(existing, url:, username:, password:, api_key:, category:, clear_api_key:)
      attributes = { url: url, username: username, category: category, enabled: true }
      attributes[:password] = password if password.present?
      attributes[:api_key] = api_key if api_key.present?
      attributes[:api_key] = nil if clear_api_key

      if existing
        # Keep an existing client's own download path; import remaps through it.
        existing.update!(attributes)
      else
        DownloadClient.create!(attributes.merge(name: available_client_name, client_type: "qbittorrent", priority: 0, download_path: nil))
      end
    end

    def start_download_monitor
      DownloadMonitorJob.ensure_running!
    rescue StandardError => e
      Rails.logger.warn "[SetupWizard] Failed to start the download monitor: #{e.message}"
    end

    def available_client_name
      DownloadClient.exists?(name: "qBittorrent") ? "qBittorrent setup" : "qBittorrent"
    end

    def credentials_present?(existing, username, password, api_key)
      return true if api_key.present?
      return true if existing&.valid_qbittorrent_api_key? && username.blank? && password.blank?

      (username.presence || existing&.username).present? && (password.presence || existing&.password).present?
    end

    def valid_api_key?(api_key)
      DownloadClient.new(client_type: "qbittorrent", api_key: api_key).valid_qbittorrent_api_key?
    end

    def container_save_path?(local_path)
      diagnostics = diagnostics_for
      diagnostics.present? && visible_save_path?(diagnostics, local_path)
    end

    # qBittorrent already writes inside this container when the path it uses
    # (the category's own save path, or the global one) is under local_path.
    def visible_save_path?(diagnostics, local_path)
      inside_path?(diagnostics[:category_save_path].presence || diagnostics[:save_path], local_path)
    end

    # Map from the global save path, unless the category saves somewhere outside it.
    def mapping_save_path(diagnostics)
      save_path = diagnostics[:save_path]
      category_save_path = diagnostics[:category_save_path]
      return save_path if category_save_path.blank? || inside_path?(category_save_path, save_path)

      category_save_path
    end

    def inside_path?(path, root)
      candidate = normalize_path(path)
      base = normalize_path(root)
      return false if candidate.blank? || base.blank?
      return true if base == "/"

      candidate == base || candidate.start_with?("#{base}/")
    end

    def saved_paths
      {
        download_local_path: SettingsService.get(:download_local_path),
        download_remote_path: SettingsService.get(:download_remote_path),
        audiobook_output_path: SettingsService.get(:audiobook_output_path),
        ebook_output_path: SettingsService.get(:ebook_output_path)
      }
    end

    def qbittorrent_warning(paths)
      client = qbittorrent_client
      # Import remaps the client's own download path, as the health check allows.
      return if client.nil? || client.download_path.present?

      diagnostics = diagnostics_for(client)
      return if diagnostics.nil?

      LibraryPathCheck.qbittorrent_message(
        save_path: diagnostics[:save_path],
        category_save_path: diagnostics[:category_save_path],
        category: client.category,
        local_path: paths[:download_local_path],
        remote_path: paths[:download_remote_path]
      )
    rescue StandardError
      nil
    end

    def audiobookshelf_warnings(paths)
      return [] unless SettingsService.active_library_platform == "audiobookshelf"
      return [] unless SettingsService.configured?(:audiobookshelf_url) && SettingsService.configured?(:audiobookshelf_api_key)

      libraries, = library_choices
      LibraryPathCheck.audiobookshelf_messages(
        libraries: libraries,
        audiobook_library_id: SettingsService.get(:audiobookshelf_audiobook_library_id),
        ebook_library_id: SettingsService.get(:audiobookshelf_ebook_library_id),
        audiobook_output_path: paths[:audiobook_output_path],
        ebook_output_path: paths[:ebook_output_path]
      )
    rescue StandardError
      []
    end

    def diagnostics_for(client = qbittorrent_client)
      return unless client&.qbittorrent_compatible?

      client.adapter.connection_diagnostics
    rescue StandardError
      nil
    end

    def normalize_path(path)
      value = path.to_s.strip.tr("\\", "/")
      return if value.blank?
      return value if value == "/"

      value = value.delete_suffix("/") while value.end_with?("/") && value.length > 1
      value
    end

    def success(notice: nil, alert: nil, stay: false)
      Result.new(success: true, notice: notice, alert: alert, stay: stay)
    end

    def failure(error)
      Result.new(success: false, error: error)
    end
  end
end
