# frozen_string_literal: true

class LibraryPlatformClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  DISPLAY_NAMES = {
    "audiobookshelf" => "Audiobookshelf",
    "bookorbit" => "BookOrbit"
  }.freeze

  class << self
    def active_platform
      SettingsService.active_library_platform
    end

    def display_name(platform = active_platform)
      DISPLAY_NAMES.fetch(platform, platform.to_s.titleize)
    end

    def configured?
      client.configured?
    end

    def libraries
      translate_errors { client.libraries }
    end

    def library(id)
      translate_errors { client.library(id) }
    end

    def library_items(id, page_size: 500)
      translate_errors { client.library_items(id, page_size: page_size) }
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
      "#{base_url.to_s.chomp("/")}/#{path_segment}/#{external_id}"
    end

    private

    def client
      client_for(active_platform)
    end

    def client_for(platform)
      case platform.to_s
      when "bookorbit"
        BookOrbitClient
      else
        AudiobookshelfClient
      end
    end

    def base_url_for(platform)
      case platform.to_s
      when "bookorbit"
        SettingsService.get(:bookorbit_url)
      else
        SettingsService.get(:audiobookshelf_url)
      end
    end

    def translate_errors
      active_client = client
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
