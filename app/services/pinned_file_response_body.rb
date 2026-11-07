# frozen_string_literal: true

# Rack response body which streams an already-open, validated regular-file
# descriptor. It intentionally does not expose #to_path, so Rack::Sendfile can
# never reopen a mutable library pathname behind the controller's validation.
class PinnedFileResponseBody
  CHUNK_SIZE = 64 * 1024

  def initialize(file, offset: 0, length: nil)
    raise ArgumentError, "response body requires an open regular file" if file.closed? || !file.stat.file?
    raise ArgumentError, "invalid response range" if offset.negative? || (length && length.negative?)

    @file = file
    @offset = offset
    @length = length
  end

  def each
    return enum_for(:each) unless block_given?

    begin
      file = @file
      raise IOError, "closed response body" unless file && !file.closed?

      file.seek(@offset)
      buffer = +""
      remaining = @length
      while remaining.nil? || remaining.positive?
        break unless file.read(remaining ? [ CHUNK_SIZE, remaining ].min : CHUNK_SIZE, buffer)

        remaining -= buffer.bytesize if remaining
        yield buffer.dup
      end
    ensure
      close
    end
  end

  # Rack calls #close even when a response body is not consumed (HEAD,
  # middleware short-circuit, or client disconnect). Keep this idempotent so
  # enumeration failures and Rack cleanup can both take the close path.
  def close
    file = @file
    @file = nil
    file&.close unless file&.closed?
  end
end
