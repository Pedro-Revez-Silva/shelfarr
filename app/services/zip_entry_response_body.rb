# frozen_string_literal: true

# Rack response body for one byte range of a ZIP entry, read through the
# already-validated package on its pinned descriptor. Like
# PinnedFileResponseBody it never exposes #to_path, and it closes the
# descriptor once the body is consumed or abandoned.
class ZipEntryResponseBody
  def initialize(file, package, path, first, last)
    @file = file
    @package = package
    @path = path
    @first = first
    @last = last
  end

  def each(&block)
    return enum_for(:each) unless block

    raise IOError, "closed response body" unless @file && !@file.closed?

    @package.stream(@path, @first, @last, &block)
  ensure
    close
  end

  def close
    file = @file
    @file = nil
    file&.close unless file&.closed?
  end
end
