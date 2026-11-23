# frozen_string_literal: true

module WebPreview
  class AdminSetup
    SUMMARIES = {
      "prowlarr" => "Where Shelfarr looks for copies of a book. Shelfarr tests the connection before it saves it.",
      "qbittorrent" => "The download client that fetches the copies Shelfarr chooses. Shelfarr tests the connection before it saves it.",
      "folders" => "Where finished books go, and where Shelfarr finds the client's downloads.",
      "audiobookshelf" => "The library platform that shows your books to readers. Shelfarr tests the connection before it saves it.",
      "search" => "What happens straight after someone asks for a book."
    }.freeze

    SENSITIVE_ADDRESS = /[@?#]/
    SAVED_ADDRESS = "the saved address"

    attr_reader :form

    def self.sensitive_address?(address)
      address.to_s.match?(SENSITIVE_ADDRESS)
    end

    def self.public_address(address)
      return address.to_s unless sensitive_address?(address)

      uri = URI.parse(address.to_s)
      uri.host.present? ? "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}" : SAVED_ADDRESS
    rescue URI::Error
      SAVED_ADDRESS
    end

    def self.address_secrets(address)
      address = address.to_s
      return [] unless sensitive_address?(address)

      [ address, address[%r{://(.*)@}m, 1] ].compact.flat_map { |value| [ value, value.inspect[1..-2] ] }
    end

    def self.redact(text, extra_secrets = [])
      return nil if text.nil?

      client = SetupWizard.qbittorrent_client
      saved = %w[prowlarr qbittorrent audiobookshelf].flat_map { |step| address_secrets(SetupWizard.saved_url(step)) }
      secrets = [ *extra_secrets, *saved, client&.password, client&.api_key ].map(&:to_s).select { |secret| secret.length >= SecretRedaction::MIN_SECRET_LENGTH }
      secrets.sort_by { |secret| -secret.length }.reduce(SecretRedaction.call(text)) { |result, secret| result.gsub(secret, SecretRedaction::MASK) }
    end

    def initialize(form)
      @form = form
    end

    def representation
      {
        step: form.step,
        steps: SetupWizard::STEPS.map { |id| { id: id, label: SetupWizard::STEP_LABELS.fetch(id) } },
        previous: form.previous_step,
        last: form.step == SetupWizard::STEPS.last,
        completed: SetupWizard.completed?,
        title: SetupWizard::STEP_LABELS.fetch(form.step),
        summary: SUMMARIES.fetch(form.step),
        warnings: form.warnings.map { |warning| self.class.redact(warning) },
        library_error: self.class.redact(form.library_error.presence),
        cards: cards
      }
    end

    private

    def cards
      case form.step
      when "prowlarr" then [ prowlarr_card ]
      when "qbittorrent" then [ qbittorrent_card ]
      when "folders" then [ folders_card ]
      when "audiobookshelf" then audiobookshelf_cards
      when "search" then [ search_card ]
      end
    end

    def prowlarr_card
      card("prowlarr", title: "Prowlarr", submit: "Test and continue", fields: [
        url_field("Prowlarr address", "http://prowlarr:9696", "Use the Docker service name or a LAN IP. localhost is Shelfarr's own container."),
        secret_field(:api_key, "Prowlarr API key", form.saved_secret, "In Prowlarr, open Settings › General and copy the API key.")
      ])
    end

    def qbittorrent_card
      card("qbittorrent", title: "qBittorrent", submit: "Test and continue", fields: [
        url_field("qBittorrent address", "http://qbittorrent:8080", "The address of the qBittorrent web interface, as Shelfarr's container reaches it."),
        text_field(:username, "Username", form.username, "Leave the username and password blank when you use an API key."),
        secret_field(:password, "Password", form.saved_secret, "A new password replaces a saved API key."),
        secret_field(:api_key, "Or a qBittorrent API key", form.saved_qbittorrent_api_key, "Use a username and password, or an API key that starts with qbt_.", placeholder: "qbt_…"),
        text_field(:category, "Category (optional)", form.category, "Leave this blank. qBittorrent creates a category folder when it needs one.")
      ])
    end

    def folders_card
      card("folders", title: "Folders", submit: "Save and continue",
        summary: "Mount the same directory at the same path in Shelfarr, qBittorrent and Audiobookshelf. Leave the download client's own download path blank.",
        fields: [
          text_field(:audiobook_output_path, "Audiobook folder", form.audiobook_output_path, "Where Shelfarr puts finished audiobooks. Audiobookshelf should scan this folder."),
          text_field(:ebook_output_path, "Ebook folder", form.ebook_output_path, "Where Shelfarr puts finished ebooks."),
          text_field(:download_local_path, "Download folder in this container", form.download_local_path, "Where Shelfarr finds qBittorrent's finished downloads."),
          text_field(:download_remote_path, "qBittorrent's path for the same folder (optional)", form.download_remote_path,
            "Only when qBittorrent reports a different path for the same files, such as /data/torrents. Filled in from qBittorrent when it differs.",
            placeholder: "Blank when qBittorrent already saves inside this container")
        ])
    end

    def audiobookshelf_cards
      connection = card("audiobookshelf_connection", phase: "connection",
        title: form.connected_to_library_platform? ? "Change the Audiobookshelf connection" : "Audiobookshelf",
        submit: form.connected_to_library_platform? ? "Test and save connection" : "Test and continue",
        collapsed: form.connected_to_library_platform?,
        fields: [
          url_field("Audiobookshelf address", "http://audiobookshelf:13378", "Use the Docker service name or a LAN IP. localhost is Shelfarr's own container."),
          secret_field(:api_key, "Audiobookshelf API token", form.saved_secret, "In Audiobookshelf, open Settings › Users, choose your user and copy the API token.")
        ])
      return [ connection ] unless form.connected_to_library_platform?

      libraries = card("audiobookshelf_libraries", phase: "libraries", title: "Libraries", submit: "Save and continue",
        summary: "Connected to #{self.class.public_address(SettingsService.get(:audiobookshelf_url))}. Choose the libraries Shelfarr should scan.",
        fields: [
          library_field(:audiobook_library_id, "Audiobook library", form.audiobook_library_id),
          library_field(:ebook_library_id, "Ebook library", form.ebook_library_id)
        ])
      [ libraries.merge(libraries: library_choices), connection ]
    end

    def search_card
      card("search", title: "Starting requests", submit: "Finish", fields: [
        toggle_field(:immediate_search_enabled, "Start searching as soon as a request is created", form.immediate_search, ""),
        toggle_field(:auto_select_enabled, "Download the best match automatically", form.auto_select,
          "Off by default, so you pick each release. When on, a release must score at least #{form.auto_select_threshold} out of 100 and have at least " \
          "#{ActionController::Base.helpers.pluralize(form.auto_select_min_seeders, "seeder")} before Shelfarr grabs it. Change these in Server › Request policy.")
      ])
    end

    def card(id, title:, submit:, fields:, summary: nil, phase: nil, collapsed: false)
      { id: id, phase: phase, title: title, summary: summary, submit: submit, collapsed: collapsed, fields: fields }
    end

    def url_field(label, placeholder, description)
      if self.class.sensitive_address?(form.url)
        return { key: "url", label: label, description: "#{description} The saved address includes sign-in details.", input: "secret", value: nil, configured: true }
      end

      { key: "url", label: label, description: description, input: "url", value: form.url.to_s, placeholder: placeholder }
    end

    def text_field(key, label, value, description, placeholder: nil)
      { key: key.to_s, label: label, description: description, input: "text", value: value.to_s, **placeholder_of(placeholder) }
    end

    def secret_field(key, label, configured, description, placeholder: nil)
      { key: key.to_s, label: label, description: description, input: "secret", value: nil, configured: configured, **placeholder_of(placeholder) }
    end

    def toggle_field(key, label, value, description)
      { key: key.to_s, label: label, description: description, input: "toggle", value: value }
    end

    def library_field(key, label, value)
      { key: key.to_s, label: label, description: "Choose Not now to skip it. You can pick one later in Server › Library and files.", input: "library",
        value: value.to_s, placeholder: "Not now" }
    end

    def placeholder_of(placeholder)
      placeholder ? { placeholder: placeholder } : {}
    end

    def library_choices
      form.libraries.map { |library| { id: library.id.to_s, name: library.name.to_s, media_type: library.media_type.to_s } }
    end
  end
end
