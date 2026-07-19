# frozen_string_literal: true

# Rack response body which streams an already-open, validated regular-file
# descriptor. It intentionally does not expose #to_path, so Rack::Sendfile can
# never reopen a mutable library pathname behind the controller's validation.
class PinnedFileResponseBody
  CHUNK_SIZE = 64 * 1024

  def initialize(file)
    raise ArgumentError, "response body requires an open regular file" if file.closed? || !file.stat.file?

    @file = file
  end

  def each
    return enum_for(:each) unless block_given?

    begin
      file = @file
      raise IOError, "closed response body" unless file && !file.closed?

      file.rewind
      buffer = +""
      yield buffer.dup while file.read(CHUNK_SIZE, buffer)
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
