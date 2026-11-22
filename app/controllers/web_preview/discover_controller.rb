# frozen_string_literal: true

class WebPreview::DiscoverController < WebPreview::APIController
  MAX_QUERY = 200
  LIMIT = 12
  CONNECTION_ERRORS = [ HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError, ComicVineClient::ConnectionError ].freeze
  ANSWER_ERRORS = [ HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error ].freeze

  def index
    query = params[:q]
    return render_error("invalid_query", :unprocessable_entity) unless valid_query?(query)

    providers = MetadataService.enabled_metadata_providers(content_kind: ContentKinds::BOOK)
    results = providers.empty? ? [] : search(query.strip)
    render json: { account: web_preview_account_id, query: query.strip, providers: providers.map { |source| MetadataSources.display_name(source) }, items: annotate(results) }
  rescue *CONNECTION_ERRORS
    render_error("search_unavailable", :service_unavailable)
  rescue *ANSWER_ERRORS
    render_error("search_failed", :bad_gateway)
  end

  private

  def valid_query?(query)
    query.is_a?(String) && query.strip.length.between?(1, MAX_QUERY) && !query.match?(/\p{Cc}/)
  end

  def search(query)
    MetadataService.search(query, limit: LIMIT, content_kind: ContentKinds::BOOK)
      .reject { |result| ContentKinds.graphic?(result.respond_to?(:content_kind) ? result.content_kind : nil) }
      .first(LIMIT)
  end

  def annotate(results)
    entries = results.filter_map do |result|
      ids = work_ids(result)
      [ result, ids ] if ids.first&.match?(WebPreview::BookPage::WORK_ID)
    end
    lookup = Book.preload_by_work_ids(entries.flat_map(&:last))
    entries.map { |result, ids| item(result, ids, lookup) }
  end

  def work_ids(result)
    sources = result.respond_to?(:sources) ? Array(result.sources).filter_map { |source| source[:work_id] } : []
    [ result.work_id, *sources ].compact_blank.map(&:to_s).uniq.first(WebPreview::BookPage::MAX_ALSO + 1)
  end

  def item(result, ids, lookup)
    source, source_id = Book.parse_work_id(ids.first)
    year = result.year.to_s.match?(/\A\d{1,4}\z/) ? result.year.to_i : nil
    {
      book: { source: source, id: source_id, also: ids.drop(1).select { |value| value.match?(WebPreview::BookPage::WORK_ID) }, metadata: handoff_token(result, ids, year) },
      title: result.title.to_s,
      author: result.author.presence,
      year: year,
      cover: { url: Consumer::SafeLink.call(result.cover_url), style: WebPreview::BookPage.cover_style(ids.first) },
      source_name: result.respond_to?(:source_name) ? result.source_name : MetadataSources.display_name(source),
      formats: WebPreview::BookPage::FORMATS.map { |book_type| { book_type: book_type, state: format_state(ids, book_type, lookup) } }
    }
  end

  def format_state(ids, book_type, lookup)
    check = DuplicateDetectionService.check(work_id: ids.first, source_work_ids: ids.drop(1), book_type: book_type, existing_books_lookup: lookup)
    return "requestable" unless check.block?
    return "in_library" if check.existing_book&.acquired?

    request = check.existing_request
    request && (request.user_id == Current.user.id || Current.user.admin?) ? "requested" : "requested_by_someone"
  end

  def handoff_token(result, ids, year)
    metadata = { work_id: ids.first, source_work_ids: ids, title: result.title, author: result.author, cover_url: result.cover_url,
      first_publish_year: year, description: result.respond_to?(:description) ? result.description.to_s.first(2_000).presence : nil, content_kind: ContentKinds::BOOK }
    token = RequestMetadataHandoff.params_for(user: Current.user, metadata: metadata)[:metadata_token]
    token if token.is_a?(String)
  end
end
