# frozen_string_literal: true

class QbittorrentDispatchTagCleanupJob < ApplicationJob
  # qBittorrent applies the tag when a slow URL fetch finishes, which recreates
  # a tag deleted while that fetch was still pending.
  CLEANUP_DELAYS = [ 2.minutes, 10.minutes, 30.minutes, 2.hours ].freeze

  queue_as :default

  def self.schedule(download_client_id, tag)
    CLEANUP_DELAYS.each do |delay|
      set(wait: delay).perform_later(download_client_id, tag)
    end
  end

  def perform(download_client_id, tag)
    return unless tag.is_a?(String) && tag.match?(DownloadClients::Qbittorrent::DISPATCH_TAG_PATTERN)

    client_record = DownloadClient.find_by(id: download_client_id)
    return unless client_record&.qbittorrent?

    client_record.adapter.remove_dispatch_tag(tag)
  end
end
