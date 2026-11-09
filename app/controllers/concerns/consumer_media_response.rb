# frozen_string_literal: true

module ConsumerMediaResponse
  private

  # A navigation to a PDF or CBZ downloads it instead of rendering it in this
  # origin; readers fetch the bytes. The policy also denies the document any
  # script, plugin, form or subresource if a browser renders it anyway.
  DOCUMENT_POLICY = "default-src 'none'; sandbox; frame-ancestors 'none'; form-action 'none'; base-uri 'none'"

  def serve_consumer_asset(book, asset_id)
    asset, file = Consumer::LibraryAssets.new(book, formats: Consumer::ReaderFormats::SUPPORTED).open(asset_id)
    etag = %Q("#{asset.id}")
    headers["Cache-Control"] = "private, no-store"
    headers["Accept-Ranges"] = "bytes"
    headers["ETag"] = etag
    headers["X-Content-Type-Options"] = "nosniff"
    fixed_layout = %w[pdf cbz].include?(asset.format)
    headers["Content-Security-Policy"] = DOCUMENT_POLICY if fixed_layout
    send_file_headers!(filename: asset.filename, type: asset.media_type, disposition: fixed_layout ? "attachment" : "inline")
    matches = request.headers["If-None-Match"].to_s.split(",").map(&:strip)
    return head :not_modified if matches.any? { |value| value == etag || value == "W/#{etag}" || value == "*" }

    range_header = request.headers["Range"]
    range_header = nil if request.headers["If-Range"].present? && request.headers["If-Range"] != etag
    range = consumer_byte_range(range_header, asset.size_bytes) unless request.head? || range_header.blank?
    if range == :invalid
      headers["Content-Range"] = "bytes */#{asset.size_bytes}"
      return head :range_not_satisfiable
    end
    first, last = range || [ 0, asset.size_bytes - 1 ]
    length = [ last - first + 1, 0 ].max
    headers["Content-Length"] = length.to_s
    headers["Content-Range"] = "bytes #{first}-#{last}/#{asset.size_bytes}" if range
    self.status = range ? :partial_content : :ok
    if request.head?
      self.response_body = ""
    else
      self.response_body = PinnedFileResponseBody.new(file, offset: first, length: length)
      file = nil
    end
  rescue Consumer::LibraryAssets::Unavailable
    render json: { error: "asset_unavailable" }, status: :gone
  ensure
    file&.close unless file&.closed?
  end

  def consumer_reading_order(book, asset_id)
    asset, pages = Consumer::LibraryAssets.new(book, formats: %w[cbz]).reading_order(asset_id)
    headers["Cache-Control"] = "private, no-store"
    headers["X-Content-Type-Options"] = "nosniff"
    { asset_id: asset.id, format: "cbz", items: pages }
  end

  def consumer_byte_range(value, size)
    match = /\Abytes=(\d*)-(\d*)\z/.match(value.to_s)
    return :invalid unless match && size.positive?

    left, right = match.captures
    return :invalid if left.empty? && right.empty?

    if left.empty?
      suffix = right.to_i
      return :invalid if suffix.zero?

      [ [ size - suffix, 0 ].max, size - 1 ]
    else
      first = left.to_i
      last = right.empty? ? size - 1 : [ right.to_i, size - 1 ].min
      first >= size || last < first ? :invalid : [ first, last ]
    end
  end
end
