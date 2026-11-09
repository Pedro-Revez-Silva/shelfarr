# frozen_string_literal: true

# Metadata search for native apps that may request. It reuses the same
# enabled metadata providers as web search and /api/v1/search, then says, for
# each format the app can read, whether the title is already in the library,
# already requested, or can be requested by this account.
class API::Consumer::V1::DiscoverController < API::Consumer::V1::BaseController
  before_action -> { consumer_scope("search:read") }

  FORMATS = Consumer::RequestView::READABLE_TYPES

  def index
    query = params[:q]
    unless query.is_a?(String) && query.strip.length.between?(1, 200)
      return render json: { error: "invalid_query" }, status: :unprocessable_entity
    end
    limit = params[:limit].to_s.match?(/\A\d{1,2}\z/) ? params[:limit].to_i.clamp(1, 20) : 12

    results = MetadataService.search(query.strip, limit: limit, content_kind: ContentKinds::BOOK)
      .reject { |result| ContentKinds.graphic?(result.respond_to?(:content_kind) ? result.content_kind : nil) }
      .first(limit)
    render json: { items: annotate(results) }
  rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError, ComicVineClient::ConnectionError
    render json: { error: "search_unavailable" }, status: :service_unavailable
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error
    render json: { error: "search_failed" }, status: :bad_gateway
  end

  private

  def annotate(results)
    entries = results.filter_map do |result|
      ids = work_ids(result)
      [ result, ids ] if ids.any?
    end
    lookup = Book.preload_by_work_ids(entries.flat_map(&:last))
    entries.map { |result, ids| item(result, ids, lookup) }
  end

  def work_ids(result)
    sources = result.respond_to?(:sources) ? Array(result.sources).filter_map { |source| source[:work_id] } : []
    [ result.work_id, *sources ].compact_blank.map(&:to_s).uniq.first(20)
  end

  def item(result, ids, lookup)
    {
      id: (result.respond_to?(:canonical_key) ? result.canonical_key : result.work_id).to_s,
      work_id: ids.first,
      source_work_ids: ids.drop(1),
      title: result.title,
      author: result.author,
      year: result.year.to_s.match?(/\A\d{1,4}\z/) ? result.year.to_i : nil,
      description: result.respond_to?(:description) ? result.description.to_s.first(2_000).presence : nil,
      cover_url: https_cover(result.cover_url),
      series_name: result.series_name,
      series_position: result.series_position&.to_s,
      source_name: result.respond_to?(:source_name) ? result.source_name : nil,
      formats: FORMATS.map { |book_type| format_state(ids, book_type, lookup) }
    }
  end

  def format_state(ids, book_type, lookup)
    check = DuplicateDetectionService.check(work_id: ids.first, source_work_ids: ids.drop(1), book_type: book_type, existing_books_lookup: lookup)
    book = check.existing_book
    state = { book_type: book_type, state: "requestable", publication_id: nil, request: nil }
    return state unless check.block?

    if book&.acquired?
      state.merge(state: "in_library", publication_id: book.id.to_s)
    elsif check.existing_request&.user_id == Current.user.id
      state.merge(state: "requested", request: Consumer::RequestView.new(check.existing_request).representation)
    else
      state.merge(state: "requested_by_someone")
    end
  end

  def https_cover(value)
    Consumer::SafeLink.call(value)
  end
end
