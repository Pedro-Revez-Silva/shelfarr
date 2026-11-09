# frozen_string_literal: true

require "digest"

# Read-along manifests and the bytes they name, for the browser reader and the
# consumer API. Every response is for one exact EPUB asset generation of an
# authorized publication:
#
#   manifest  the validated alignment (see Consumer::ReadAlong), with URLs
#   resource  one entry of that EPUB the manifest lists (text, styles, images,
#             fonts, or narration audio), served as an attachment with single
#             byte ranges; nothing outside the package's own manifest is served
#   audio     one audiobook file an imported alignment is bound to, served
#             under the ebook's path only while that alignment is current
module ConsumerReadAlongResponse
  RESOURCE_POLICY = "default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'"
  ERRORS = { "unaligned" => :not_found, "stale" => :conflict, "invalid" => :unprocessable_entity }.freeze

  private

  # route_names: :web or :api
  def render_read_along_manifest(book, asset_id, routes:)
    status = read_along_status(book, asset_id)
    headers["Cache-Control"] = "private, no-store"
    headers["X-Content-Type-Options"] = "nosniff"
    return render(json: read_along_error(status), status: ERRORS.fetch(status.status)) unless status.status == "available"

    render json: read_along_manifest(book, asset_id, status, routes: routes)
  rescue Consumer::LibraryAssets::Unavailable
    render json: { error: "asset_unavailable" }, status: :gone
  end

  def serve_read_along_resource(book, asset_id, path)
    status = read_along_status(book, asset_id)
    raise Consumer::LibraryAssets::Unavailable unless status.status == "available"

    core = status.core
    path = path.to_s
    listed = core[:resources].any? { |resource| resource[:href] == path } ||
      core[:audio].any? { |track| track[:kind] == "epub_resource" && track[:href] == path }
    return render(json: { error: "resource_not_found" }, status: :not_found) unless listed

    asset, file = Consumer::LibraryAssets.new(book, formats: %w[epub]).open(asset_id)
    package = Consumer::EpubPackage.open(file)
    entry = package.entry(path)
    return render(json: { error: "resource_not_found" }, status: :not_found) unless entry && package.servable?(path) && entry.size <= package.size_limit(path)

    etag = %("#{Digest::SHA256.hexdigest("#{asset.id}\0#{path}")}")
    headers["Cache-Control"] = "private, no-store"
    headers["Accept-Ranges"] = "bytes"
    headers["ETag"] = etag
    headers["X-Content-Type-Options"] = "nosniff"
    headers["Content-Security-Policy"] = RESOURCE_POLICY
    headers["X-Shelfarr-Read-Along"] = core[:generation]
    send_file_headers!(filename: File.basename(path), type: package.media_type_of(path), disposition: "attachment")
    matches = request.headers["If-None-Match"].to_s.split(",").map(&:strip)
    return head :not_modified if matches.any? { |value| value == etag || value == "W/#{etag}" || value == "*" }

    range_header = request.headers["Range"]
    range_header = nil if request.headers["If-Range"].present? && request.headers["If-Range"] != etag
    range = consumer_byte_range(range_header, entry.size) unless request.head? || range_header.blank?
    if range == :invalid || entry.size.zero? && range
      headers["Content-Range"] = "bytes */#{entry.size}"
      return head :range_not_satisfiable
    end
    first, last = range || [ 0, entry.size - 1 ]
    length = [ last - first + 1, 0 ].max
    headers["Content-Length"] = length.to_s
    headers["Content-Range"] = "bytes #{first}-#{last}/#{entry.size}" if range
    self.status = range ? :partial_content : :ok
    if request.head? || length.zero?
      self.response_body = ""
    else
      self.response_body = ZipEntryResponseBody.new(file, package, path, first, last)
      file = nil
    end
  rescue Consumer::LibraryAssets::Unavailable, Consumer::EpubPackage::Invalid
    render json: { error: "asset_unavailable" }, status: :gone
  ensure
    file&.close unless file&.closed?
  end

  def serve_read_along_audio(book, asset_id, audio_asset_id)
    status = read_along_status(book, asset_id)
    track = status.status == "available" && status.core[:audio].find { |audio| audio[:kind] == "publication_asset" && audio[:asset_id] == audio_asset_id.to_s }
    return render(json: { error: "asset_unavailable" }, status: :gone) unless track

    audiobook = Book.acquired.where(book_type: :audiobook).find_by(id: track[:publication_id])
    return render(json: { error: "asset_unavailable" }, status: :gone) unless audiobook

    serve_consumer_asset(audiobook, track[:asset_id])
  rescue Consumer::LibraryAssets::Unavailable
    render json: { error: "asset_unavailable" }, status: :gone
  end

  def read_along_status(book, asset_id)
    asset = Consumer::LibraryAssets.new(book, formats: %w[epub]).find(asset_id)
    raise Consumer::LibraryAssets::Unavailable, "This media edition has changed; refresh the publication" unless asset

    Consumer::ReadAlong.for(book, asset)
  end

  def read_along_error(status)
    { error: "read_along_#{status.status}", status: status.status, source: status.source, reason: status.reason }.compact
  end

  def read_along_manifest(book, asset_id, status, routes:)
    core = status.core
    base = read_along_base(book, asset_id, routes)
    resource_url = ->(href) { "#{base}/resources/#{href.split("/").map { |part| ERB::Util.url_encode(part) }.join("/")}" }
    audio = core[:audio].map do |track|
      url = if track[:kind] == "epub_resource"
        resource_url.call(track[:href])
      else
        routes == :web ? consumer_read_along_audio_path(book, asset_id, track[:asset_id]) : api_consumer_v1_asset_read_along_audio_path(book, asset_id, track[:asset_id])
      end
      value = track.merge(url: url)
      value[:content_url] = api_consumer_v1_asset_path(track[:publication_id], track[:asset_id]) if routes == :api && track[:kind] == "publication_asset"
      value
    end
    core.merge(publication_id: book.id.to_s, manifest_url: base, resources_url: "#{base}/resources/", audio: audio,
      resources: core[:resources].map { |resource| resource.merge(url: resource_url.call(resource[:href])) })
  end

  def read_along_base(book, asset_id, routes)
    routes == :web ? consumer_read_along_path(book, asset_id) : api_consumer_v1_asset_read_along_path(book, asset_id)
  end
end
