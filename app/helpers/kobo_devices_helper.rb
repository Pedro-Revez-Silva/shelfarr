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
      in [ "superseded", _ ] then "Kept a newer place from another device#{saved_place_text(progress)}. Kobo place: #{place}."
      in [ "needs_choice", "same_time" ] then "Kobo and another device saved different places at the same moment. Kobo place: #{place}#{saved_place_text(progress, prefix: '; Shelfarr place')}."
      in [ "needs_choice", "saved_time_unknown" ] then "Shelfarr's saved place has no reading time, so it can't be compared with the Kobo place (#{place})."
      in [ "needs_choice", _ ] then "Another device saved a place while this one arrived. Kobo place: #{place}."
      in [ "unknown_time", _ ] then "Kobo didn't say when it reached this place (#{place}), so it wasn't shared automatically."
      in [ "clock_ahead", _ ] then "This Kobo's clock is ahead of the server, so its place (#{place}) wasn't shared. Check the reader's date and time."
      in [ "unsupported", "no_location" ] then "Kobo sent only a percentage (#{place}), not a chapter, so this place can't be shared."
      in [ "unsupported", "invalid_percent" ] then "Kobo sent a place Shelfarr can't read, so it wasn't shared."
      in [ "unsupported", _ ] then "Kobo's location doesn't match a chapter in this edition, so it wasn't shared."
      in [ "edition_changed", _ ] then "The library file changed after it was sent. Send it again to share reading places."
      else "Shelfarr couldn't check this book's file. It tries again when the Kobo next saves a place."
      end
    tone = bridge["status"] == "shared" ? :ok : (choosable ? :choice : :warning)
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
