# frozen_string_literal: true

module Consumer::LibraryHelper
  def consumer_progress_label(publication)
    progress = publication[:progress]
    return "Files unavailable" if publication[:assets].empty?
    return "Finished" if publication[:reading_status] == "finished"
    return "Unread · saved place kept" if publication[:reading_status] == "unread" && progress
    return publication[:book_type] == "ebook" ? "Start reading" : "Start listening" unless progress
    return "New edition · start afresh" unless publication[:assets].any? { |asset| asset[:id] == progress[:asset_id] }
    return "Resume at #{consumer_time(progress[:position_seconds])}" if progress[:position_seconds]

    percent = progress.dig(:locator, "locations", "totalProgression")
    percent ? "#{(percent * 100).round}% read" : "Continue reading"
  end

  def consumer_time(seconds)
    minutes, seconds = seconds.to_i.divmod(60)
    hours, minutes = minutes.divmod(60)
    hours.positive? ? format("%d:%02d:%02d", hours, minutes, seconds) : format("%d:%02d", minutes, seconds)
  end

  def consumer_cover_style(book)
    hash = book.id.to_s.bytes.reduce(0x811c9dc5) { |value, byte| ((value ^ byte) * 0x01000193) & 0xffffffff }
    [ "clay", "moss", "slate", "oat", "plum", "stone" ][hash % 6]
  end
end
