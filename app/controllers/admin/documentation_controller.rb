# frozen_string_literal: true

module Admin
  class DocumentationController < BaseController
    def index
      @settings_reference = build_settings_reference
      @download_client_fields = download_client_fields
      @path_template_variables = PathTemplateService::VARIABLES
    end

    private

    def build_settings_reference
      grouped = SettingsService::DEFINITIONS.group_by { |_, definition| definition[:category] }

      grouped.transform_values do |entries|
        entries.map do |key, definition|
          {
            key: key,
            type: definition[:type],
            default: format_default_value(key, definition[:default]),
            description: definition[:description]
          }
        end.sort_by { |setting| setting[:key].to_s }
      end
    end

    def format_default_value(key, value)
      return "(generated per install)" if key == :api_token
      return "(empty)" if value == ""

      value.is_a?(String) ? value : value.inspect
    end

    def download_client_fields
      [
        {
          key: "name",
          required: true,
          description: "Friendly label shown in the UI (for example, Home qBittorrent)."
        },
        {
          key: "type",
          required: true,
          description: "Client implementation to use (qBittorrent, SABnzbd, NZBGet, Deluge, Transmission)."
        },
        {
          key: "url",
          required: true,
          description: "Base URL of the client, including protocol and port."
        },
        {
          key: "username",
          required: false,
          description: "Login username for clients that require authentication."
        },
        {
          key: "password",
          required: false,
          description: "Login password for clients that require authentication."
        },
        {
          key: "api_key",
          required: false,
          description: "API key used by SABnzbd."
        },
        {
          key: "category",
          required: false,
          description: "Category/tag assigned to downloads in the client."
        },
        {
          key: "download_path",
          required: false,
          description: "Override path for completed downloads for this specific client."
        },
        {
          key: "enabled",
          required: true,
          description: "Whether this client can be selected for new downloads."
        },
        {
          key: "priority",
          required: true,
          description: "Ordering within the same client type. Lower values are tried first."
        }
      ]
    end
  end
end
