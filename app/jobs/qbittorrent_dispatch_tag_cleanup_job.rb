# frozen_string_literal: true

class QbittorrentDispatchTagCleanupJob < ApplicationJob
  class CleanupError < StandardError; end

  # qBittorrent applies the tag when a slow URL fetch finishes, which recreates
  # a tag deleted while that fetch was still pending.
  CLEANUP_DELAYS = [ 2.minutes, 10.minutes, 30.minutes, 2.hours ].freeze

  queue_as :default
  # An unsuccessful deleteTags leaves the tag in place. Treat that as a failure
  # so the job is retried instead of finishing successfully.
  retry_on CleanupError, wait: :polynomially_longer, attempts: 5

  def self.schedule(download_client_id, tag)
    CLEANUP_DELAYS.each do |delay|
      set(wait: delay).perform_later(download_client_id, tag) # rubocop:disable Shelfarr/SelfEnqueue -- All four cleanup deadlines must coexist.
    end
  end

  def perform(download_client_id, tag)
    return unless tag.is_a?(String) && tag.match?(DownloadClients::Qbittorrent::DISPATCH_TAG_PATTERN)

    client_record = DownloadClient.find_by(id: download_client_id)
    return unless client_record&.qbittorrent?

    removed = client_record.adapter.remove_dispatch_tag(tag)
    return if RemoteResult.succeeded?(removed)

    raise CleanupError, "qBittorrent did not delete the dispatch tag"
  rescue CleanupError
    raise
  rescue StandardError => error
    raise CleanupError, "qBittorrent dispatch tag cleanup failed: #{error.class}"
  end
end
