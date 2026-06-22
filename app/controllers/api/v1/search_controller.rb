# frozen_string_literal: true

class API::V1::SearchController < API::V1::ApplicationController
  before_action -> { require_scope!("search:read") }

  def index
    query = params[:q].to_s.strip
    if query.blank?
      render json: { errors: [ "Query can't be blank" ] }, status: :unprocessable_entity
      return
    end

    results = MetadataService.search(query, limit: search_limit)
    render json: { results: results.map { |result| search_result_payload(result) } }
  rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError
    render json: { errors: [ "Unable to connect to metadata service" ] }, status: :service_unavailable
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
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
      series_position: result.series_position
    }
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
