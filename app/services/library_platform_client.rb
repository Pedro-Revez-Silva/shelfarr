# frozen_string_literal: true

require "uri"

class LibraryPlatformClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  DISPLAY_NAMES = {
    "audiobookshelf" => "Audiobookshelf",
    "bookorbit" => "BookOrbit",
    "grimmory" => "Grimmory"
  }.freeze

  class << self
    def active_platform
      SettingsService.active_library_platform
    end

    def display_name(platform = active_platform)
      DISPLAY_NAMES.fetch(platform, platform.to_s.titleize)
    end

    def configured?(platform: active_platform)
      client_for(platform).configured?
    end

    def libraries(platform: active_platform)
      translate_errors(platform: platform) { client_for(platform).libraries }
    end

    def library(id)
      translate_errors { client.library(id) }
    end

    def library_items(id, page_size: 500, platform: active_platform)
      translate_errors(platform: platform) do
        client_for(platform).library_items(id, page_size: page_size)
      end
    end

    def scan_library(id)
      translate_errors { client.scan_library(id) }
    end

    def delete_item_by_path(path)
      translate_errors { client.delete_item_by_path(path) }
    end

    def test_connection
      translate_errors { client.test_connection }
    end

    def reset_connections!
      AudiobookshelfClient.reset_connection!
      BookOrbitClient.reset_connection!
      GrimmoryClient.reset_connection!
    end

    def reset_connection!
      reset_connections!
    end

    def item_url(item)
      item_url_for(
        platform: item.library_platform.presence || active_platform,
        external_id: item.audiobookshelf_id
      )
    end

    def item_url_for(platform:, external_id:)
      return nil if external_id.blank?

      base_url = base_url_for(platform)
      return nil if base_url.blank?

      path_segment = platform.to_s == "audiobookshelf" ? "item" : "book"
      encoded_id = URI.encode_www_form_component(external_id.to_s).gsub("+", "%20")
      uri = URI.parse(base_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?

      uri.query = nil
      uri.fragment = nil
      uri.path = "#{uri.path.to_s.chomp("/")}/#{path_segment}/#{encoded_id}"
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    private

    def client
      client_for(active_platform)
    end

    def client_for(platform)
      case platform.to_s
      when "bookorbit"
        BookOrbitClient
      when "grimmory"
        GrimmoryClient
      else
        AudiobookshelfClient
      end
    end

    def base_url_for(platform)
      case platform.to_s
      when "bookorbit"
        SettingsService.get(:bookorbit_url)
      when "grimmory"
        SettingsService.get(:grimmory_url)
      else
        SettingsService.get(:audiobookshelf_url)
      end
    end

    def translate_errors(platform: active_platform)
      active_client = client_for(platform)
      yield
    rescue active_client::AuthenticationError => e
      raise AuthenticationError, e.message
    rescue active_client::ConnectionError => e
      raise ConnectionError, e.message
    rescue active_client::NotConfiguredError => e
      raise NotConfiguredError, e.message
    rescue active_client::Error => e
      raise Error, e.message
    end
  end
end
