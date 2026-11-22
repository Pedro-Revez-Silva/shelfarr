# frozen_string_literal: true

class WebPreview::Admin::LibraryController < WebPreview::Admin::BaseController
  def show
    libraries = ServerSettings::LibraryInventory.platform_libraries
    inventory = ServerSettings::LibraryInventory.new
    render json: {
      account: web_preview_account_id,
      platform: LibraryPlatformClient.display_name,
      configured: LibraryPlatformClient.configured?,
      libraries: libraries.is_a?(RemoteResult::Failed) ? nil : libraries.map { |library| { id: library.id.to_s, name: library.name.to_s, media_type: library.media_type.to_s } },
      inventory: {
        count: inventory.count,
        available: inventory.available_count,
        missing: inventory.missing_count,
        last_synced_at: inventory.last_synced_at&.iso8601,
        recent: inventory.recent_items.map { |item| item_json(item) }
      }
    }
  end

  def sync
    outcome = if ServerSettings::LibraryInventory.start_sync
      success("#{LibraryPlatformClient.display_name} library sync started.")
    else
      failure("#{LibraryPlatformClient.display_name} is not configured. Enter connection details first.")
    end
    render json: { account: web_preview_account_id, outcome: outcome }
  end

  private

  def item_json(item)
    {
      id: item.id.to_s,
      title: item.display_title.to_s.truncate(90),
      author: item.display_author.presence,
      url: Consumer::SafeLink.call(item.audiobookshelf_url),
      missing: item.missing?,
      details: [ item.library_id, *item.detail_badges.first(4), item.identifier_label ].compact.map(&:to_s)
    }
  end
end
