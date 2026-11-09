# frozen_string_literal: true

module KoboDevicesHelper
  Notice = Data.define(:tone, :text, :choosable)

  def kobo_mode_label(device)
    device.store_coexistence? ? "Kobo Store + Shelfarr" : "Shelfarr books only"
  end

  def kobo_store_status(device)
    checked = device.store_checked_at && "#{time_ago_in_words(device.store_checked_at)} ago"
    case device.store_status
    when "ok" then Notice.new(:ok, "Kobo Store answered #{checked}.", false)
    when "unavailable"
      Notice.new(:warning, "Kobo Store couldn't be reached #{checked}. Shelfarr books still synced; Store changes arrive at a later sync.", false)
    when "rejected"
      Notice.new(:warning, "Kobo refused this reader's Store sync #{checked}. Shelfarr books still synced. If it continues, open the Kobo Store on the reader, or sign in there again with the same Kobo account.", false)
    when "authorization"
      Notice.new(:warning, "Kobo asked this reader to sign in again #{checked}. Sync again on the reader. If Kobo keeps asking, sign in there with the same Kobo account.", false)
    else Notice.new(:info, "Waiting for this reader's first Store sync through Shelfarr.", false)
    end
  end

  def kobo_place_notice(delivery, progress)
    bridge = delivery.progress_bridge
    return Notice.new(:info, "No Kobo reading place yet.", false) if bridge.blank? || bridge["status"] == "no_place"

    place = kobo_place_text(bridge)
    choosable = Kobo::ProgressBridge::CHOICE_STATUSES.include?(bridge["status"]) && bridge["locator"].present?
    text =
      case [ bridge["status"], bridge["reason"] ]
      in [ "shared", "chosen" ] then "Shelfarr resumes at the Kobo place you chose (#{place})."
      in [ "shared", _ ] then "Reading place shared with Shelfarr: #{place}."
      in [ "echo", _ ] then "This Kobo reported the place Shelfarr sent it (#{place}); nothing new to share."
      in [ "superseded", _ ] then "Kept a newer place from another device#{saved_place_text(progress)}. Kobo place: #{place}."
      in [ "needs_choice", "same_time" ] then "Kobo and another device saved different places at the same moment. Kobo place: #{place}#{saved_place_text(progress, prefix: '; Shelfarr place')}."
      in [ "needs_choice", "saved_time_unknown" ] then "Shelfarr's saved place has no reading time, so it can't be compared with the Kobo place (#{place})."
      in [ "needs_choice", "edition_unverified" ] then "This reader may still have the previous edition. Its place (#{place}) wasn't shared automatically. Use Kobo place only if that chapter and percentage fit the current file."
      in [ "needs_choice", _ ] then "Another device saved a place while this one arrived. Kobo place: #{place}."
      in [ "unknown_time", _ ] then "Kobo didn't say when it reached this place (#{place}), so it wasn't shared automatically."
      in [ "clock_ahead", _ ] then "This Kobo's clock is ahead of the server, so its place (#{place}) wasn't shared. Check the reader's date and time."
      in [ "unsupported", "private_edition" ] then "This copy came from a Kobo account, not the Shelfarr library, so its place (#{place}) stays on this reader."
      in [ "unsupported", "no_location" ] then "Kobo sent only a percentage (#{place}), not a chapter, so this place can't be shared."
      in [ "unsupported", "invalid_percent" ] then "Kobo sent a place Shelfarr can't read, so it wasn't shared."
      in [ "unsupported", _ ] then "Kobo's location doesn't match a chapter in this edition, so it wasn't shared."
      in [ "edition_changed", "not_downloaded" ] then "Waiting for this reader to download the sent file before sharing its place."
      in [ "edition_changed", _ ] then "The library file changed after it was sent. Send it again to share reading places."
      else "Shelfarr couldn't check this book's file. It tries again when the Kobo next saves a place."
      end
    tone = %w[shared echo].include?(bridge["status"]) ? :ok : (choosable ? :choice : :warning)
    Notice.new(tone, text, choosable)
  end

  # What happened to the owner's Shelfarr place for this reader.
  def kobo_outbound_notice(delivery, progress)
    outbound = delivery.progress_outbound
    return Notice.new(:info, "No Shelfarr reading place to send yet. Read this book in Shelfarr, then sync this Kobo.", false) if outbound.blank? || progress.nil?

    stale = outbound["progress_version"] != progress.version || outbound["progress_mutation_id"] != progress.client_mutation_id
    return Notice.new(:info, "Shelfarr has a newer place for this book. It is checked at this Kobo's next sync.", false) if stale

    place = shelfarr_place_text(outbound)
    choosable = outbound["status"] == "needs_choice" && outbound["span"].present?
    text =
      case [ outbound["status"], outbound["reason"] ]
      in [ "queued", "chosen" ] then "Your chosen Shelfarr place (#{place}) waits for this Kobo's next Wi-Fi sync."
      in [ "queued", _ ] then "Shelfarr place (#{place}) waits for this Kobo's next Wi-Fi sync. Kobo opens the nearest sentence, so the page can differ slightly."
      in [ "sent", _ ] then "Shelfarr place (#{place}) sent with the sync #{time_ago_in_words(Time.iso8601(outbound['sent_at']))} ago. The Kobo shows it when you next open the book."
      in [ "at_place", _ ] then "This Kobo is already at Shelfarr's place (#{place})."
      in [ "kobo_place", _ ] then "Shelfarr's latest place came from this Kobo, so it isn't sent back."
      in [ "waiting", _ ] then "Waiting for this Kobo to download the book before sending Shelfarr's place."
      in [ "needs_choice", "kobo_newer" ] then "This Kobo has a newer place#{kobo_time_text(outbound['kobo_at'])}, so Shelfarr's older place (#{place}) wasn't sent."
      in [ "needs_choice", "same_time" ] then "This Kobo and Shelfarr saved different places at the same moment. Shelfarr place: #{place}."
      in [ "needs_choice", "unknown_time" ] then "Shelfarr's place (#{place}) has no reading time, so it can't be compared with this Kobo's place."
      in [ "needs_choice", "kobo_time_unknown" ] then "This Kobo's place has no reading time, so Shelfarr's place (#{place}) wasn't sent automatically."
      in [ "needs_choice", "edition_unverified" ] then "This reader may still have the previous edition, so Shelfarr's place (#{place}) wasn't sent automatically. Send it only if the reader has the current file."
      in [ "unsupported", "plain_epub" ] then "This is a plain EPUB. Kobo reads it with an engine whose places Shelfarr can't name, so Shelfarr places aren't sent. A KEPUB file of this book can receive them."
      in [ "unsupported", "different_edition" ] then "Shelfarr's place is in a different file of this book, so it isn't sent to this reader."
      in [ "unsupported", "file_changed" ] then "The library file changed after it was sent. Send it again to receive Shelfarr places."
      in [ "unsupported", "location_not_in_edition" ] then "Shelfarr's place names a chapter this edition doesn't have, so it wasn't sent."
      in [ "unsupported", "no_kobo_spans" ] then "This chapter has no Kobo sentence markers, so Shelfarr's place can't be named for the Kobo."
      in [ "unsupported", "not_an_ebook" ] then "Shelfarr's place isn't a text place, so it isn't sent."
      in [ "unsupported", _ ] then "This chapter is too large or can't be read safely, so Shelfarr's place wasn't sent."
      else "Shelfarr couldn't check this book's file. It tries again when Shelfarr's place next changes."
      end
    tone = %w[queued sent at_place].include?(outbound["status"]) ? :ok : (choosable ? :choice : (%w[kobo_place waiting].include?(outbound["status"]) ? :info : :warning))
    Notice.new(tone, text, choosable)
  end

  private

  def kobo_place_text(bridge)
    parts = []
    parts << "#{number_with_precision(bridge['percent'], precision: 0)}%" if bridge["percent"]
    if bridge["observed_at"]
      parts << "read #{time_ago_in_words(Time.iso8601(bridge['observed_at']))} ago"
    end
    parts.presence&.join(", ") || "no percentage"
  end

  def shelfarr_place_text(outbound)
    parts = []
    parts << "chapter #{outbound['chapter']} of #{outbound['chapters']}" if outbound["chapter"] && outbound["chapters"]
    parts << "#{outbound['percent']}% of the book" if outbound["percent"]
    at = outbound["reason"] == "chosen" ? nil : outbound["observed_at"]
    parts << "read #{time_ago_in_words(Time.iso8601(at))} ago" if at
    parts.presence&.join(", ") || "no percentage"
  end

  def kobo_time_text(at)
    at ? " (read #{time_ago_in_words(Time.iso8601(at))} ago)" : ""
  end

  def saved_place_text(progress, prefix: " (")
    return "" unless progress

    total = progress.locator&.dig("locations", "totalProgression")
    details = []
    details << "#{(total * 100).round}%" if total.is_a?(Numeric)
    details << "read #{time_ago_in_words(progress.observed_at)} ago" if progress.observed_at
    return "" if details.empty?

    prefix == " (" ? " (#{details.join(', ')})" : "#{prefix}: #{details.join(', ')}"
  end
end
