# frozen_string_literal: true

# The browser reader's view of a publication: the shared consumer projection
# with same-session media and progress URLs under the deployment subpath, and
# the scope that binds this browser's outbox and downloads to the account.
module ConsumerWebPublication
  WEB_EBOOK_LIMIT = 32.megabytes

  private

  def web_publication(book, representation)
    representation[:assets].each { |asset| asset[:content_url] = consumer_asset_path(book, asset[:id]) }
    representation.merge(progress_url: consumer_progress_path(book), cover_style: helpers.consumer_cover_style(book),
      progress_scope: { account: Current.user.id.to_s, base: request.script_name.to_s },
      offline: { supported: web_offline_supported?(representation) })
  end

  # Downloads are offered only for media this browser can open again: an
  # EPUB within the web renderer's limit, or audio tracks. Other formats in
  # the shared projection (such as fixed-layout files) are never offered.
  def web_offline_supported?(representation)
    assets = representation[:assets]
    return false if assets.empty?
    return assets.all? { |asset| asset[:media_type].to_s.start_with?("audio/") } if representation[:book_type] == "audiobook"

    assets.all? { |asset| asset[:format] == "epub" && asset[:size_bytes] <= WEB_EBOOK_LIMIT }
  end
end
