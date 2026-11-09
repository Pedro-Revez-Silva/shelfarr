# frozen_string_literal: true

# Stock Kobo's embedded browser is deliberately not subject to the web app's
# modern-browser gate or cookie authentication. Every endpoint uses the device
# capability, even when a request includes Kobo's own unrelated bearer token.
#
# With Store coexistence, Shelfarr answers for its own selections and passes
# everything else to Kobo's Store API with the reader's own sign-in. The
# reader's Kobo credentials are forwarded per request and never stored.
class KoboController < ActionController::API
  include ActionController::DataStreaming
  include PinnedFileRanges

  before_action :authenticate_device
  MAX_BODY_BYTES = KoboBodyLimit::MAX_BYTES
  # Resources Shelfarr must answer so its selections appear beside the Store's.
  # Every other Store resource keeps Kobo's own URL, including sign-in.
  COEXISTENCE_RESOURCES = %w[library_sync library_metadata reading_state image_host image_url_template image_url_quality_template].freeze
  STORE_IMAGE = "https://cdn.kobo.com/book-images"

  def initialization
    unless coexisting?
      headers["x-kobo-apitoken"] = "e30="
      return render json: { Resources: local_resources }
    end

    response = store_request(path: "/v1/initialization")
    # Kobo's own refusal (an expired or invalid sign-in) reaches the reader
    # unchanged, so it keeps its cached resources and recovers as with Kobo.
    return render_store(response) if response.status.between?(400, 499)

    resources = (response.json["Resources"] if response.status == 200)
    raise Kobo::StoreProxy::Unavailable unless resources.is_a?(Hash)

    headers["x-kobo-apitoken"] = response.headers["x-kobo-apitoken"] if response.headers["x-kobo-apitoken"]
    render json: { Resources: resources.merge(local_resources.slice(*COEXISTENCE_RESOURCES)) }
  rescue Kobo::StoreProxy::Unavailable
    # Local books still sync. Sign-in resources point at Shelfarr's relay,
    # which never issues placeholder credentials in this mode.
    @device.update_columns(store_status: "unavailable", store_checked_at: Time.current)
    render json: { Resources: local_resources }
  rescue Kobo::StoreProxy::InvalidRequest
    head :not_found
  end

  def auth
    return proxy_store if coexisting?

    body = bounded_json
    return if performed?

    @device.update_columns(placeholder_auth_at: Time.current)
    render json: { AccessToken: SecureRandom.base64(24), RefreshToken: SecureRandom.base64(24),
      TokenType: "Bearer", TrackingId: SecureRandom.uuid, UserKey: body["UserKey"].to_s.first(512) }
  end

  def sync
    raw = request.headers["x-kobo-synctoken"]
    result =
      if coexisting?
        Kobo::StoreSync.new(@device, endpoint: endpoint).call(raw, headers: device_headers, query: request.query_string)
      else
        sync_service.call(Kobo::SyncCursor.new(@device).read(raw).local)
      end
    return render_store(result) if result.is_a?(Kobo::StoreProxy::Response)

    headers.merge!(result.headers) if result.respond_to?(:headers)
    headers["x-kobo-synctoken"] = result.token
    headers["x-kobo-sync"] = "continue" if result.more
    render json: result.items
  end

  def metadata
    return render(json: [ sync_service.metadata(delivery) ]) unless coexisting?

    ids = params[:entitlement_id].to_s.split(",")
    selected = @device.kobo_deliveries.where(entitlement_id: ids).index_by(&:entitlement_id)
    # A shared book whose grant ended is answered by nobody: never the Store.
    ended = local_entitlement_ids(ids) - selected.keys
    ended |= selected.reject { |_, entry| entry.deliverable? }.keys
    selected.except!(*ended)
    ids -= ended
    return head(:not_found) if ids.empty?

    store_ids = ids - selected.keys
    return render(json: selected.values.map { |entry| sync_service.metadata(entry) }) if store_ids.empty?

    response = store_request(path: "/v1/library/#{store_ids.join(',')}/metadata")
    return render_store(response) unless response.status == 200 && selected.any?

    render json: response.json(Array) + selected.values.map { |entry| sync_service.metadata(entry) }
  rescue Kobo::StoreProxy::Unavailable
    head :service_unavailable
  rescue Kobo::StoreProxy::InvalidRequest
    head :not_found
  end

  def download
    selected = delivery
    return head :not_found unless selected.revision_id == params[:revision_id]

    file = selected.open_file
    selected.update_columns(last_download_at: Time.current) unless request.head?
    send_pinned_range(file, filename: selected.publication.fetch("filename"), etag: %Q("#{selected.revision_id}"))
  rescue KoboPublication::Unavailable
    head :gone
  end

  def cover
    selected = @device.kobo_deliveries.find_by(entitlement_id: params[:entitlement_id])
    return store_image unless selected

    image = selected.cover
    return head :not_found unless image

    send_data image.first, type: image.last, disposition: "inline"
  rescue KoboPublication::Unavailable
    head :not_found
  end

  # The Kobo state is saved for this physical reader as Kobo sent it. When the
  # owner shares reading places, a supported place is also offered to shared
  # progress; Kobo's own location values are never treated as app locators.
  # When the reader receives Shelfarr places, GET answers with the owner's
  # current Shelfarr place where it is newer and maps to a real Kobo span.
  def state
    selected = @device.kobo_deliveries.find_by(entitlement_id: params[:entitlement_id])
    return proxy_store if !selected && coexisting?
    return head(:not_found) if selected && !selected.deliverable?

    selected ||= delivery
    unless request.put?
      Kobo::OutboundProgress.refresh(@device, only: selected) unless request.head?
      progress = Kobo::OutboundProgress.progresses_for(@device, [ selected ])[selected.book_id] if @device.receive_progress?
      reading_state, shelfarr = Kobo::OutboundProgress.serve(selected, progress)
      Kobo::OutboundProgress.sent!([ selected ]) if shelfarr && !request.head?
      render json: reading_state ? [ reading_state ] : []
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
      Kobo::ProgressBridge.new(selected).call(incoming["CurrentBookmark"]) if incoming.key?("CurrentBookmark")
      result = incoming.keys.index_with { { "Result" => "Success" } }.transform_keys { |key| "#{key}Result" }
      render json: { RequestResult: "Success", UpdateResults: [ result.merge(
        "EntitlementId" => selected.entitlement_id, "LastModified" => now, "PriorityTimestamp" => now) ] }
    end
  end

  def tags
    return proxy_store if coexisting?

    render json: { Tags: [] }
  end

  def unsupported
    return proxy_store if coexisting?

    head :not_found
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

  def coexisting?
    @device.store_coexistence?
  end

  def local_resources
    base = endpoint
    {
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
  end

  # The path after this reader's capability prefix, which never reaches Kobo.
  def store_path
    request.path_info.delete_prefix("/kobo/#{params[:kobo_token]}")
  end

  # Only the reader's own protocol headers are relayed; cookies, forwarding
  # headers and Shelfarr's combined sync cursor are not.
  def device_headers
    request.headers.env.each_with_object({}) do |(key, value), result|
      if key.start_with?("HTTP_")
        result[key.delete_prefix("HTTP_").downcase.tr("_", "-")] = value
      elsif key == "CONTENT_TYPE"
        result["content-type"] = value
      end
    end
  end

  def store_request(path: store_path, method: "GET", body: nil)
    Kobo::StoreProxy.new.call(method: method, path: path, query: request.query_string, headers: device_headers, body: body)
  end

  def proxy_store
    # Delivery deletion removes access, not knowledge that this UUID was
    # issued locally. Never forward a later private bookmark to Kobo's Store,
    # including batched IDs or methods handled by the unsupported-path relay.
    ids = store_path.match(%r{\A/v1/library/([^/]+)(?:/|\z)})&.[](1)&.split(",")
    return head(:not_found) if ids && local_entitlement_ids(ids).any?

    method = request.head? ? "HEAD" : request.request_method
    body = request.raw_post.to_s if %w[POST PUT PATCH DELETE].include?(method)
    return head(:content_too_large) if body.to_s.bytesize > MAX_BODY_BYTES

    render_store(store_request(method: method, body: body.presence))
  rescue Kobo::StoreProxy::Unavailable
    head :service_unavailable
  rescue Kobo::StoreProxy::InvalidRequest
    head :not_found
  end

  def render_store(response)
    response.headers.except("content-type").each { |name, value| headers[name] = value }
    # Kobo's bytes are served on Shelfarr's origin: never as active content.
    headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
    return head(response.status) if request.head? || response.body.empty?

    render body: response.body, status: response.status, content_type: response.headers.fetch("content-type")
  end

  # Store covers are public images on Kobo's fixed image host. The reader gets
  # a redirect, so no Store request or credential is relayed for images.
  def store_image
    return head(:not_found) unless coexisting?
    return head(:not_found) if local_entitlement_ids([ params[:entitlement_id] ]).any?

    id, width, height, quality, greyscale = params.values_at(:entitlement_id, :width, :height, :quality, :greyscale).map(&:to_s)
    unless id.match?(/\A[A-Za-z0-9-]{1,80}\z/) && [ width, height ].all? { |value| value.match?(/\A\d{1,5}\z/) } &&
        %w[true false].include?(greyscale) && (params[:quality].nil? || quality.match?(/\A\d{1,3}\z/))
      return head(:not_found)
    end
    path = params[:quality].nil? ? [ id, width, height, "false" ] : [ id, width, height, quality, greyscale ]
    redirect_to "#{STORE_IMAGE}/#{path.join('/')}/image.jpg", allow_other_host: true, status: :found
  end

  def sync_service
    KoboSync.new(@device, endpoint: endpoint)
  end

  def local_entitlement_ids(ids)
    @device.kobo_local_entitlements.where(entitlement_id: ids).pluck(:entitlement_id)
  end

  def delivery
    found = @device.kobo_deliveries.find_by!(entitlement_id: params[:entitlement_id])
    raise ActiveRecord::RecordNotFound unless found.deliverable?

    found
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
