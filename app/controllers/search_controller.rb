# frozen_string_literal: true

class SearchController < ApplicationController
  include ActionController::Live

  def index
    @query = params[:q]
    @content_kind = normalized_content_kind(params[:content_kind])
  end

  def results
    @query = params[:q].to_s.strip
    @content_kind = normalized_content_kind(params[:content_kind])

    if @query.blank?
      @results = []
      @error = nil
      @audiobookshelf_matches = []
      @existing_books_lookup = {}
    else
      begin
        @results = search_metadata(@query)
        @audiobookshelf_matches = audiobookshelf_matches_for(@results)
        @existing_books_lookup = existing_books_lookup_for(@results)
        @error = nil
      rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError, ComicVineClient::ConnectionError => e
        @results = []
        @audiobookshelf_matches = []
        @existing_books_lookup = {}
        @error = "Unable to connect to metadata service. Please try again later."
        Rails.logger.error("Metadata service connection error: #{e.message}")
      rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error => e
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
    @content_kind = normalized_content_kind(params[:content_kind])

    response.headers["Content-Type"] = "text/vnd.turbo-stream.html; charset=utf-8"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    if @query.blank?
      write_search_results_stream(results: [], loading: false)
      return
    end

    providers = MetadataService.enabled_metadata_providers(content_kind: @content_kind)
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

    each_provider_search(query) do |provider, results|
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
  rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError, ComicVineClient::ConnectionError => e
    Rails.logger.error("Metadata service connection error: #{e.message}")
    write_search_results_stream(results: [], error: "Unable to connect to metadata service. Please try again later.", loading: false)
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error => e
    Rails.logger.error("Metadata service error: #{e.message}")
    write_search_results_stream(results: [], error: "Search failed. Please try again.", loading: false)
  ensure
    response.stream.close
  end

  def details
    @work_id = params[:work_id]
    @source_work_ids = Array(params[:source_work_ids]).compact_blank
    @title = params[:title]
    @author = params[:author]
    @cover_url = params[:cover_url]
    @first_publish_year = params[:first_publish_year]
    @description = params[:description]
    @content_kind = normalized_content_kind(params[:content_kind])
    @available_book_types = Array(params[:available_book_types]).compact_blank
    @publisher = params[:publisher]
    @issue_number = params[:issue_number]
    @release_date = params[:release_date]
    @series = params[:series]
    @series_position = params[:series_position]
    @collection_source = params[:collection_source]
    @collection_id = params[:collection_id]
    @collection_title = params[:collection_title]
    @modal = params[:modal] == "1"

    enrich_details_from_source
    normalize_available_book_types!
    @collection_items = collection_preview_items

    return redirect_to search_path, alert: "Missing title information" if @work_id.blank? || @title.blank?
  end

  def close_modal
    render :close_modal, layout: false
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

  def search_metadata(query)
    return MetadataService.search(query, content_kind: @content_kind) if @content_kind.present?

    MetadataService.search(query)
  end

  def each_provider_search(query)
    if @content_kind.present?
      MetadataService.each_provider_search(query, content_kind: @content_kind) { |provider, results| yield provider, results }
    else
      MetadataService.each_provider_search(query) { |provider, results| yield provider, results }
    end
  end

  def normalized_content_kind(value)
    normalized = value.to_s.strip.downcase
    %w[book comic manga all].include?(normalized) ? normalized : nil
  end

  def normalize_available_book_types!
    @available_book_types = [ "comicbook" ] if @available_book_types.blank? && %w[comic manga].include?(@content_kind.to_s)
    @available_book_types = %w[audiobook ebook] if @available_book_types.blank?
  end

  def enrich_details_from_source
    return if @work_id.blank?

    source, source_id = Book.parse_work_id(@work_id)
    case source
    when "hardcover"
      enrich_hardcover_details(source_id)
    when "comic_vine"
      enrich_comic_vine_details(source_id)
    end
  rescue HardcoverClient::Error, ComicVineClient::Error, MetadataService::Error => e
    Rails.logger.warn("[SearchController] Details enrichment failed for #{@work_id}: #{e.message}")
  end

  def enrich_hardcover_details(source_id)
    return unless HardcoverClient.configured?

    details = HardcoverClient.book(source_id)
    @title = @title.presence || details.title
    @author = @author.presence || details.author
    @cover_url = @cover_url.presence || details.cover_url
    @first_publish_year = @first_publish_year.presence || details.release_year
    @description = @description.presence || details.description
    @series = @series.presence || details.series_name
    @series_position = @series_position.presence || details.series_position

    return if details.series_id.blank? || details.series_name.blank?

    @collection_source = @collection_source.presence || "hardcover"
    @collection_id = @collection_id.presence || details.series_id
    @collection_title = @collection_title.presence || details.series_name
  end

  def enrich_comic_vine_details(source_id)
    return unless ComicVineClient.configured?

    details = ComicVineClient.details(source_id, content_kind: @content_kind)
    return unless details

    @title = @title.presence || details.title
    @author = @author.presence || details.creators
    @cover_url = @cover_url.presence || details.cover_url
    @first_publish_year = @first_publish_year.presence || details.year
    @description = @description.presence || details.description
    @content_kind = @content_kind.presence || details.content_kind
    @publisher = @publisher.presence || details.publisher
    @issue_number = @issue_number.presence || details.issue_number
    @release_date = @release_date.presence || details.release_date
    @series = @series.presence || details.series_name
    @series_position = @series_position.presence || details.issue_number
    @collection_source = @collection_source.presence || "comic_vine"
    @collection_id = @collection_id.presence || details.collection_id
    @collection_title = @collection_title.presence || details.collection_title
  end

  def collection_preview_items
    return [] if @collection_source.blank? || @collection_id.blank?

    MetadataCollectionService.expand(
      source: @collection_source,
      collection_id: @collection_id,
      collection_title: @collection_title,
      content_kind: @content_kind,
      limit: 12
    )
  rescue MetadataCollectionService::Error, HardcoverClient::Error, ComicVineClient::Error => e
    Rails.logger.warn("[SearchController] Collection preview failed for #{@collection_source}:#{@collection_id}: #{e.message}")
    []
  end
end
