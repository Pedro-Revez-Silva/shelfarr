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
end
