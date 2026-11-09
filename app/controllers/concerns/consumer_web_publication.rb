# frozen_string_literal: true

# The browser reader's view of a publication: the shared consumer projection
# with same-session media and progress URLs under the deployment subpath, and
# the scope that binds this browser's outbox and downloads to the account.
module ConsumerWebPublication
  WEB_EBOOK_LIMIT = 32.megabytes

  private

  def web_publication(book, representation)
    representation[:assets].each do |asset|
      asset[:content_url] = consumer_asset_path(book, asset[:id])
      asset[:reading_order_url] = consumer_asset_reading_order_path(book, asset[:id]) if asset.key?(:reading_order_url)
    end
    representation.merge(progress_url: consumer_progress_path(book), cover_style: helpers.consumer_cover_style(book),
      progress_scope: { account: Current.user.id.to_s, base: request.script_name.to_s },
      offline: { supported: web_offline_supported?(representation) })
  end

  # Downloads are offered only for media this browser can open again: audio
  # tracks, EPUBs within the web renderer's limit, and PDFs and CBZs (read
  # page by page with ranges, so the server's own limits apply). A CBZ
  # download also stores its reading order.
  def web_offline_supported?(representation)
    assets = representation[:assets]
    return false if assets.empty?
    return assets.all? { |asset| asset[:media_type].to_s.start_with?("audio/") } if representation[:book_type] == "audiobook"

    assets.all? { |asset| %w[pdf cbz].include?(asset[:format]) || (asset[:format] == "epub" && asset[:size_bytes] <= WEB_EBOOK_LIMIT) }
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
