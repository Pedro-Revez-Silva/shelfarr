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
    results, failed = search(query.strip)
    return render_error("search_unavailable", :service_unavailable) if providers.any? && failed.size == providers.size

    render json: { account: web_preview_account_id, query: query.strip, providers: names(providers), unavailable: names(failed), items: annotate(results),
      request_options: WebPreview::RequestOptions.new.representation }
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
    by_provider = {}
    failed = []
    MetadataService.each_provider_search(query, limit: LIMIT, content_kind: ContentKinds::BOOK) do |provider, results, did_fail|
      by_provider[provider] = results
      failed << provider if did_fail
    end
    results = MetadataService.aggregate_provider_results(MetadataService.merge_provider_results(by_provider), limit: LIMIT, content_kind: ContentKinds::BOOK)
      .reject { |result| ContentKinds.graphic?(result.respond_to?(:content_kind) ? result.content_kind : nil) }
      .first(LIMIT)
    [ results, failed ]
  end

  def names(sources)
    sources.map { |source| MetadataSources.display_name(source) }
  end

  def annotate(results)
    results.filter_map do |result|
      ids = work_ids(result)
      item(result, ids) if ids.first&.match?(WebPreview::BookPage::WORK_ID)
    end
  end

  def work_ids(result)
    sources = result.respond_to?(:sources) ? Array(result.sources).filter_map { |source| source[:work_id] } : []
    [ result.work_id, *sources ].compact_blank.map(&:to_s).uniq.first(WebPreview::BookPage::MAX_LINKS)
  end

  def item(result, ids)
    source, source_id = Book.parse_work_id(ids.first)
    year = result.year.to_s.match?(/\A\d{1,4}\z/) ? result.year.to_i : nil
    page = WebPreview::BookPage.new(user: Current.user, work_id: ids.first, links: ids.drop(1))
    return if ContentKinds.graphic?(page.content_kind)

    {
      book: { source: source, id: source_id, metadata: handoff_token(result, page, year) },
      title: result.title.to_s,
      author: result.author.presence,
      year: year,
      cover: { url: Consumer::SafeLink.call(result.cover_url), style: WebPreview::BookPage.cover_style(ids.first) },
      source_name: result.respond_to?(:source_name) ? result.source_name : MetadataSources.display_name(source),
      formats: page.states
    }
  end

  def handoff_token(result, page, year)
    WebPreview::BookHandoff.store(user: Current.user, details: { work_id: page.work_ids.first, links: page.work_ids.drop(1), title: result.title, author: result.author,
      year: year, description: result.respond_to?(:description) ? result.description.to_s.first(2_000).presence : nil, cover_url: result.cover_url })
  end
end
