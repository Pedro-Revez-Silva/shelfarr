# frozen_string_literal: true

class SearchController < ApplicationController
  include ActionController::Live

  def index
    @query = params[:q]
  end

  def results
    @query = params[:q].to_s.strip

    if @query.blank?
      @results = []
      @error = nil
      @audiobookshelf_matches = []
      @existing_books_lookup = {}
    else
      begin
        @results = MetadataService.search(@query)
        @audiobookshelf_matches = audiobookshelf_matches_for(@results)
        @existing_books_lookup = existing_books_lookup_for(@results)
        @error = nil
      rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError => e
        @results = []
        @audiobookshelf_matches = []
        @existing_books_lookup = {}
        @error = "Unable to connect to metadata service. Please try again later."
        Rails.logger.error("Metadata service connection error: #{e.message}")
      rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
        @results = []
        @audiobookshelf_matches = []
        @existing_books_lookup = {}
        @error = "Search failed. Please try again."
        Rails.logger.error("Metadata service error: #{e.message}")
      end
    end

    respond_to do |format|
      format.turbo_stream
      format.html { render :index }
    end
  end

  def stream_results
    @query = params[:q].to_s.strip

    response.headers["Content-Type"] = "text/vnd.turbo-stream.html; charset=utf-8"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    if @query.blank?
      write_search_results_stream(results: [], loading: false)
      return
    end

    providers = MetadataService.enabled_metadata_providers
    if providers.empty?
      write_search_results_stream(results: [], loading: false)
      return
    end

    query = @query
    results_by_provider = {}
    completed_providers = []

    write_search_results_stream(
      results: [],
      loading: true,
      pending_providers: providers,
      completed_providers: completed_providers
    )

    MetadataService.each_provider_search(query) do |provider, results|
      completed_providers << provider
      results_by_provider[provider] = results

      candidates = MetadataService.aggregate_provider_results(
        MetadataService.merge_provider_results(results_by_provider)
      )
      pending_providers = providers - completed_providers

      write_search_results_stream(
        results: candidates,
        loading: pending_providers.any?,
        pending_providers: pending_providers,
        completed_providers: completed_providers
      )
    end
  rescue IOError, ActionController::Live::ClientDisconnected
    Rails.logger.info("Search results stream disconnected")
  rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError => e
    Rails.logger.error("Metadata service connection error: #{e.message}")
    write_search_results_stream(results: [], error: "Unable to connect to metadata service. Please try again later.", loading: false)
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
    Rails.logger.error("Metadata service error: #{e.message}")
    write_search_results_stream(results: [], error: "Search failed. Please try again.", loading: false)
  ensure
    response.stream.close
  end

  private

  def write_search_results_stream(results:, loading:, pending_providers: [], completed_providers: [], error: nil)
    response.stream.write(
      render_search_results_stream(
        results: results,
        loading: loading,
        pending_providers: pending_providers,
        completed_providers: completed_providers,
        error: error
      )
    )
  end

  def render_search_results_stream(results:, loading:, pending_providers:, completed_providers:, error:)
    @results = results
    @error = error
    @search_loading = loading
    @search_pending_provider_names = provider_names(pending_providers)
    @search_completed_provider_names = provider_names(completed_providers)
    enrichment = stream_enrichment_for(results, loading: loading)
    @audiobookshelf_matches = enrichment[:audiobookshelf_matches]
    @existing_books_lookup = enrichment[:existing_books_lookup]

    render_to_string(
      template: "search/results",
      formats: [ :turbo_stream ],
      layout: false
    )
  end

  def audiobookshelf_matches_for(results)
    if results.any? && LibraryItem.available_for_matching.exists?
      AudiobookshelfLibraryMatcherService.matches_for_many(results, limit_per_result: 3)
    else
      Array.new(results.size) { [] }
    end
  end

  def stream_enrichment_for(results, loading:)
    return { audiobookshelf_matches: [], existing_books_lookup: {} } if loading

    {
      audiobookshelf_matches: audiobookshelf_matches_for(results),
      existing_books_lookup: existing_books_lookup_for(results)
    }
  end

  def existing_books_lookup_for(results)
    work_ids = results.flat_map { |result| source_work_ids_for(result) }
    Book.preload_by_work_ids(work_ids)
  end

  def source_work_ids_for(result)
    if result.respond_to?(:sources)
      Array(result.sources).filter_map { |source| source[:work_id] }
    else
      [ result.work_id ]
    end
  end

  def provider_names(providers)
    providers.map { |provider| MetadataSources.display_name(provider) }
  end
end
