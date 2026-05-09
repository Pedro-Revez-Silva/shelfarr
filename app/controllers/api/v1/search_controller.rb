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
  rescue HardcoverClient::ConnectionError, OpenLibraryClient::ConnectionError
    render json: { errors: [ "Unable to connect to metadata service" ] }, status: :service_unavailable
  rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
    render json: { errors: [ e.message.presence || "Search failed" ] }, status: :bad_gateway
  end

  private

  def search_limit
    (params[:limit].presence || 10).to_i.clamp(1, 20)
  end

  def search_result_payload(result)
    {
      work_id: result.work_id,
      source: result.source,
      source_id: result.source_id,
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
end
