# frozen_string_literal: true

# Single-range delivery without handing a mutable pathname to Rack::Sendfile.
# Suitable for EPUB retries and future audio/offline clients.
module PinnedFileRanges
  private

  def send_pinned_range(file, filename:, etag:)
    size = file.stat.size
    headers["Accept-Ranges"] = "bytes"
    headers["ETag"] = etag
    send_file_headers!(filename: filename, type: "application/epub+zip", disposition: "attachment")

    range_header = request.headers["Range"]
    range_header = nil if request.headers["If-Range"].present? && request.headers["If-Range"] != etag
    # Range only applies to GET; HEAD describes the complete representation.
    range = parse_byte_range(range_header, size) if request.get? && range_header.present?
    if range == :invalid
      headers["Content-Range"] = "bytes */#{size}"
      head :range_not_satisfiable
      return
    end

    first, last = range || [ 0, size - 1 ]
    length = [ last - first + 1, 0 ].max
    headers["Content-Length"] = length.to_s
    headers["Content-Range"] = "bytes #{first}-#{last}/#{size}" if range
    self.status = range ? :partial_content : :ok
    if request.head?
      self.response_body = ""
      return
    end

    self.response_body = PinnedFileResponseBody.new(file, offset: first, length: length)
    file = nil
  ensure
    file&.close unless file&.closed?
  end

  def parse_byte_range(value, size)
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
