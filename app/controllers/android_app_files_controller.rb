# frozen_string_literal: true

# The server's Android feed and the cached APK bytes it points to. Public: no
# session, cookie or bearer is read. Bytes come only from the verified cache
# (never a redirect upstream), opened without following symlinks and chosen
# by the promoted build, not by the requested name.
class AndroidAppFilesController < ActionController::API
  include PinnedFileRanges

  FEED_SCHEMA_VERSION = 1
  APK_TYPE = "application/vnd.android.package-archive"

  before_action :public_response
  before_action :require_enabled_channel

  def feed
    headers["Cache-Control"] = "no-store"
    release = store.ready_release(channel)
    return not_ready unless release

    render json: feed_document(release)
  end

  def apk
    release, file = store.open_apk(channel, params[:file].to_s)
    return render(json: { error: "not_found" }, status: :not_found) unless file

    file = nil if serve(release, file) == :streaming
  ensure
    file&.close unless file&.closed?
  end

  private

  def channel
    params[:channel].to_s
  end

  def store
    @store ||= AndroidUpdates::Store.new
  end

  def public_response
    headers["X-Content-Type-Options"] = "nosniff"
    headers["Referrer-Policy"] = "no-referrer"
  end

  def require_enabled_channel
    return if AndroidUpdates::Configuration.current.enabled?(channel)

    headers["Cache-Control"] = "no-store"
    render json: { error: "channel_disabled" }, status: :not_found
  end

  def not_ready
    headers["Retry-After"] = "3600"
    render json: { error: "not_ready" }, status: :service_unavailable
  end

  def feed_document(release)
    {
      schema_version: FEED_SCHEMA_VERSION,
      channel: release.channel,
      package_name: release.package_name,
      version_code: release.version_code,
      version_name: release.version_name,
      apk_url: android_app_apk_url(channel: release.channel, file: release.file_name),
      size_bytes: release.size_bytes,
      sha256: release.sha256,
      min_sdk: release.min_sdk,
      release_notes: release.release_notes,
      consumer_api_versions: release.consumer_api_versions
    }.compact
  end

  # Returns :streaming once the response body owns the file.
  def serve(release, file)
    etag = %Q("#{release.sha256}")
    headers["Cache-Control"] = "public, max-age=31536000, immutable"
    headers["ETag"] = etag
    headers["Accept-Ranges"] = "bytes"
    headers["Content-Type"] = APK_TYPE
    headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: "shelfarr-#{release.channel}-#{release.version_name}.apk"
    )
    matches = request.headers["If-None-Match"].to_s.split(",").map(&:strip)
    return head(:not_modified) if matches.any? { |value| value == etag || value == "W/#{etag}" || value == "*" }

    range_header = request.headers["Range"]
    range_header = nil if request.headers["If-Range"].present? && request.headers["If-Range"] != etag
    range = parse_byte_range(range_header, release.size_bytes) if request.get? && range_header.present?
    if range == :invalid
      headers["Content-Range"] = "bytes */#{release.size_bytes}"
      return head(:range_not_satisfiable)
    end

    first, last = range || [ 0, release.size_bytes - 1 ]
    headers["Content-Length"] = (last - first + 1).to_s
    headers["Content-Range"] = "bytes #{first}-#{last}/#{release.size_bytes}" if range
    self.status = range ? :partial_content : :ok
    # HEAD describes the complete file without reading it.
    return self.response_body = "" if request.head?

    self.response_body = PinnedFileResponseBody.new(file, offset: first, length: last - first + 1)
    :streaming
  end
end
