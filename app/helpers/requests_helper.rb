# frozen_string_literal: true

module RequestsHelper
  REQUEST_STATUS_COLORS = {
    "pending" => "bg-yellow-500/20 text-yellow-400",
    "searching" => "bg-blue-500/20 text-blue-400",
    "not_found" => "bg-orange-500/20 text-orange-400",
    "downloading" => "bg-indigo-500/20 text-indigo-400",
    "processing" => "bg-cyan-500/20 text-cyan-400",
    "completed" => "bg-green-500/20 text-green-400",
    "failed" => "bg-red-500/20 text-red-400"
  }.freeze

  DOWNLOAD_STATUS_COLORS = {
    "pending" => "bg-yellow-500/20 text-yellow-400",
    "queued" => "bg-yellow-500/20 text-yellow-400",
    "downloading" => "bg-blue-500/20 text-blue-400",
    "completed" => "bg-green-500/20 text-green-400",
    "failed" => "bg-red-500/20 text-red-400"
  }.freeze

  def request_status_color(status)
    REQUEST_STATUS_COLORS[status.to_s] || "bg-gray-700 text-gray-300"
  end

  def download_status_color(status)
    DOWNLOAD_STATUS_COLORS[status.to_s] || "bg-gray-700 text-gray-300"
  end

  def diagnostic_event_color(event)
    case event.level.to_s
    when "error"
      "bg-red-500/20 text-red-400"
    when "warn"
      "bg-orange-500/20 text-orange-400"
    when "info"
      "bg-green-500/20 text-green-400"
    else
      "bg-gray-700 text-gray-300"
    end
  end

  def diagnostic_event_title(event)
    case event.event_type
    when "attention_flagged" then "Attention Flagged"
    when "download_queued" then "Download Queued"
    when "dispatch_started" then "Dispatch Started"
    when "dispatched" then "Sent To Client"
    when "dispatch_failed" then "Dispatch Failed"
    when "dispatch_stalled" then "Dispatch Stalled"
    when "completed" then "Download Completed"
    when "failed" then "Download Failed"
    else
      event.event_type.to_s.tr("_", " ").titleize
    end
  end

  def diagnostic_event_message(event)
    details = event.details.to_h.with_indifferent_access
    parts = []
    parts << event.message if event.message.present?
    parts << "Client: #{details[:client_name]}" if details[:client_name].present?
    parts << "Type: #{details[:download_type]}" if details[:download_type].present?
    parts << "External ID: #{details[:external_id]}" if details[:external_id].present?
    parts << "Download ##{event.download_id}" if event.download_id.present?
    parts << "Path: #{details[:download_path]}" if details[:download_path].present?
    parts << "Source: #{details[:trigger]}" if details[:trigger].present?
    parts.compact.join(" | ")
  end
end
