# frozen_string_literal: true

# Public facts a native app may read before it signs in: the consumer API
# generations this server implements and where its Android builds are. No
# bearer is read, nothing personal is returned and nothing is fetched upstream.
class API::Consumer::V1::ServerController < ActionController::API
  SCHEMA_VERSION = 1

  def show
    headers["Cache-Control"] = "no-cache"
    headers["X-Content-Type-Options"] = "nosniff"
    configuration = AndroidUpdates::Configuration.current
    render json: {
      schema_version: SCHEMA_VERSION,
      server_version: Consumer::ServerInfo.server_version,
      consumer_api_versions: Consumer::ServerInfo::API_VERSIONS,
      consumer_features: Consumer::ServerInfo::FEATURES,
      reader_formats: Consumer::ReaderFormats::SUPPORTED,
      reader_features: Consumer::ReaderFeatures::SUPPORTED,
      read_along_manifest_versions: [ Consumer::ReadAlong::VERSION ],
      android: configuration.channels.index_with { |channel| android_channel(channel) }
    }
  end

  private

  # Paths include the deployment subpath and stay on this server.
  def android_channel(channel)
    {
      feed_url: android_app_feed_path(channel: channel, format: :json),
      download_page_url: channel == "release" ? android_app_path : android_app_path(channel: channel)
    }
  end
end
