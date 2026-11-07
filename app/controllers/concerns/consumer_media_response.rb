# frozen_string_literal: true

module ConsumerMediaResponse
  private

  def serve_consumer_asset(book, asset_id)
    asset, file = Consumer::LibraryAssets.new(book).open(asset_id)
    etag = %Q("#{asset.id}")
    headers["Cache-Control"] = "private, no-store"
    headers["Accept-Ranges"] = "bytes"
    headers["ETag"] = etag
    headers["X-Content-Type-Options"] = "nosniff"
    send_file_headers!(filename: asset.filename, type: asset.media_type, disposition: "inline")
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
