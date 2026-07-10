# frozen_string_literal: true

class API::V1::SearchController < API::V1::ApplicationController
  before_action -> { require_scope!("search:read") }

  def index
    query = params[:q].to_s.strip
    if query.blank?
      render json: { errors: [ "Query can't be blank" ] }, status: :unprocessable_entity
      return
    end

    results = MetadataService.search(query, limit: search_limit, content_kind: normalized_content_kind)
    render json: { results: results.map { |result| search_result_payload(result) } }
  rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError, ComicVineClient::ConnectionError
    render json: { errors: [ "Unable to connect to metadata service" ] }, status: :service_unavailable
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error => e
    render json: { errors: [ e.message.presence || "Search failed" ] }, status: :bad_gateway
  end

  private

  def search_limit
    (params[:limit].presence || 10).to_i.clamp(1, 20)
  end

  def search_result_payload(result)
    {
      canonical_key: result.respond_to?(:canonical_key) ? result.canonical_key : result.work_id,
      work_id: result.work_id,
      source: result.source,
      source_id: result.source_id,
      source_name: result.source_name,
      source_url: result.source_url,
      source_attribution: result.source_attribution,
      sources: result_sources_payload(result),
      editions: result.respond_to?(:editions) ? result.editions : [],
      confidence: result.respond_to?(:confidence) ? result.confidence : nil,
      title: result.title,
      author: result.author,
      year: result.year,
      cover_url: result.cover_url,
      has_audiobook: result.has_audiobook,
      has_ebook: result.has_ebook,
      series_name: result.series_name,
      series_position: result.series_position,
      content_kind: result_content_kind(result),
      available_book_types: RequestOptionPolicy.book_types_for(result_content_kind(result)),
      collection_source: result.respond_to?(:collection_source) ? result.collection_source : nil,
      collection_id: result.respond_to?(:collection_id) ? result.collection_id : nil,
      collection_title: result.respond_to?(:collection_title) ? result.collection_title : nil,
      issue_number: result.respond_to?(:issue_number) ? result.issue_number : nil,
      release_date: result.respond_to?(:release_date) ? result.release_date : nil
    }
  end

  def normalized_content_kind
    ContentKinds.normalize(params[:content_kind], default: nil)
  end

  def result_content_kind(result)
    ContentKinds.normalize(result.respond_to?(:content_kind) ? result.content_kind : nil, default: "book")
  end

  def result_sources_payload(result)
    if result.respond_to?(:sources)
      result.sources.map do |source|
        {
          source: source[:source],
          source_id: source[:source_id],
          source_name: source[:source_name],
          source_url: source[:source_url],
          work_id: source[:work_id]
        }
      end
    else
      [ {
        source: result.source,
        source_id: result.source_id,
        source_name: result.source_name,
        source_url: result.source_url,
        work_id: result.work_id
      } ]
    end
  end
end
