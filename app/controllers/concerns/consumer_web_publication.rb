# frozen_string_literal: true

# The browser reader's view of a publication: the shared consumer projection
# with same-session media and progress URLs under the deployment subpath, and
# the scope that binds this browser's outbox and downloads to the account.
module ConsumerWebPublication
  WEB_EBOOK_LIMIT = 32.megabytes

  private

  def web_publication(book, representation)
    paired = nil
    representation[:assets].each do |asset|
      asset[:content_url] = consumer_asset_path(book, asset[:id])
      asset[:reading_order_url] = consumer_asset_reading_order_path(book, asset[:id]) if asset.key?(:reading_order_url)
      read_along = asset[:read_along]
      next unless read_along

      read_along[:manifest_url] = consumer_read_along_path(book, asset[:id]) if read_along.key?(:manifest_url)
      paired ||= paired_audiobook(read_along) if read_along[:status] == "available" && read_along[:source] == "imported"
    end
    value = representation.merge(progress_url: consumer_progress_path(book), cover_style: helpers.consumer_cover_style(book),
      progress_scope: { account: Current.user.id.to_s, base: request.script_name.to_s },
      offline: { supported: web_offline_supported?(representation) })
    value[:read_along_audiobook] = paired if paired
    value
  end

  # An imported alignment narrates with a separate audiobook. Listening in
  # read-along saves that audiobook's own place too, through its own outbox.
  def paired_audiobook(read_along)
    id = read_along.dig(:audiobook, :id)
    audiobook = Book.acquired.where(book_type: :audiobook).find_by(id: id)
    return nil unless audiobook

    { id: audiobook.id.to_s, title: audiobook.title, progress_url: consumer_progress_path(audiobook),
      progress: Current.user.consumer_progresses.find_by(book: audiobook)&.representation }
  end

  # Downloads are offered only for media this browser can open again: audio
  # tracks, EPUBs within the web renderer's limit, and PDFs and CBZs (read
  # page by page with ranges, so the server's own limits apply). A CBZ
  # download also stores its reading order. A read-along EPUB is read entry
  # by entry, so its limit applies to the text, styles and images it loads,
  # not to narration audio, which is streamed or played from the cache.
  def web_offline_supported?(representation)
    assets = representation[:assets]
    return false if assets.empty?
    return assets.all? { |asset| asset[:media_type].to_s.start_with?("audio/") } if representation[:book_type] == "audiobook"

    assets.all? do |asset|
      %w[pdf cbz].include?(asset[:format]) || (asset[:format] == "epub" &&
        (asset[:size_bytes] <= WEB_EBOOK_LIMIT || web_read_along_text_bytes(asset).to_i.between?(1, WEB_EBOOK_LIMIT)))
    end
  end

  def web_read_along_text_bytes(asset)
    asset.dig(:read_along, :text_bytes) if asset.dig(:read_along, :status) == "available"
  end

  # The browser reader opens every supported reading format.
  def web_reader_formats
    Consumer::ReaderFormats::WEB
  end

  def web_book(id)
    raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/)

    Book.acquired.where(book_type: Consumer::LibraryScope.types(nil, graphic: true)).find(id)
  end
end
