# frozen_string_literal: true

# Stock Kobo's embedded browser is deliberately not subject to the web app's
# modern-browser gate or cookie authentication. Every endpoint uses the device
# capability, even when a request includes Kobo's own unrelated bearer token.
class KoboController < ActionController::API
  include ActionController::DataStreaming
  include PinnedFileRanges

  before_action :authenticate_device
  MAX_BODY_BYTES = 64 * 1024

  def initialization
    base = endpoint
    resources = {
      "library_sync" => "#{base}/v1/library/sync",
      "library_metadata" => "#{base}/v1/library/{Ids}/metadata",
      "reading_state" => "#{base}/v1/library/{Ids}/state",
      "device_auth" => "#{base}/v1/auth/device",
      "device_refresh" => "#{base}/v1/auth/refresh",
      "image_host" => base,
      "image_url_template" => "#{base}/{ImageId}/{Width}/{Height}/false/image.jpg",
      "image_url_quality_template" => "#{base}/{ImageId}/{Width}/{Height}/{Quality}/{IsGreyscale}/image.jpg",
      "tags" => "#{base}/v1/library/tags"
    }
    headers["x-kobo-apitoken"] = "e30="
    render json: { Resources: resources }
  end

  def auth
    body = bounded_json
    return if performed?

    render json: { AccessToken: SecureRandom.base64(24), RefreshToken: SecureRandom.base64(24),
      TokenType: "Bearer", TrackingId: SecureRandom.uuid, UserKey: body["UserKey"].to_s.first(512) }
  end

  def sync
    result = sync_service.call(request.headers["x-kobo-synctoken"])
    headers["x-kobo-synctoken"] = result.token
    headers["x-kobo-sync"] = "continue" if result.more
    render json: result.items
  end

  def metadata
    render json: [ sync_service.metadata(delivery) ]
  end

  def download
    selected = delivery
    return head :not_found unless selected.revision_id == params[:revision_id]

    file = selected.open_file
    selected.update_columns(last_download_at: Time.current) if request.get?
    send_pinned_range(file, filename: selected.publication.fetch("filename"), etag: %Q("#{selected.revision_id}"))
  rescue KoboPublication::Unavailable
    head :gone
  end

  def cover
    selected = delivery
    file = selected.open_file
    image = KoboPublication.new(selected.book).cover(file)
    return head :not_found unless image

    send_data image.first, type: image.last, disposition: "inline"
  rescue KoboPublication::Unavailable
    head :not_found
  ensure
    file&.close unless file&.closed?
  end

  # Saved only for this physical reader. This is not cross-device progress:
  # Kobo's format-specific locations are not interchangeable with app locators.
  def state
    selected = delivery
    if request.get?
      render json: selected.reading_state ? [ selected.reading_state ] : []
    else
      body = bounded_json
      return if performed?

      states = body["ReadingStates"]
      unless states.is_a?(Array) && states.size == 1 && states.first.is_a?(Hash) &&
          [ nil, selected.entitlement_id ].include?(states.first["EntitlementId"])
        return head :bad_request
      end
      incoming = states.first.slice("CurrentBookmark", "Statistics", "StatusInfo")
      return head :bad_request unless incoming.values.all? { |value| value.is_a?(Hash) }

      now = Time.current.utc.iso8601(3)
      saved = (selected.reading_state || {}).merge(incoming).merge(
        "EntitlementId" => selected.entitlement_id, "Created" => selected.created_at.utc.iso8601(3),
        "LastModified" => now, "PriorityTimestamp" => now)
      selected.update_columns(reading_state: saved)
      result = incoming.keys.index_with { { "Result" => "Success" } }.transform_keys { |key| "#{key}Result" }
      render json: { RequestResult: "Success", UpdateResults: [ result.merge(
        "EntitlementId" => selected.entitlement_id, "LastModified" => now, "PriorityTimestamp" => now) ] }
    end
  end

  def tags
    render json: { Tags: [] }
  end

  private

  def authenticate_device
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
    headers["X-Content-Type-Options"] = "nosniff"
    @device = KoboDevice.authenticate(params[:kobo_token])
    head :unauthorized unless @device
  end

  def endpoint
    @device.endpoint(params[:kobo_token])
  end

  def sync_service
    KoboSync.new(@device, endpoint: endpoint)
  end

  def delivery
    @device.kobo_deliveries.find_by!(entitlement_id: params[:entitlement_id])
  end

  def bounded_json
    data = request.body.read(MAX_BODY_BYTES + 1)
    return head(:content_too_large) if data.bytesize > MAX_BODY_BYTES

    parsed = JSON.parse(data)
    return head(:bad_request) unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    head :bad_request
  end
end
