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
    # Live returns up the Rack stack after the first write commits, so URLMap can
    # restore SCRIPT_NAME while later chunks are still rendering. Preserve it for URLs.
    @live_script_name = request.script_name.presence
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
        MetadataService.merge_provider_results(results_by_provider),
        content_kind: @content_kind
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
    return if redirect_legacy_details_handoff?

    cached_metadata = details_handoff_metadata
    @work_id = params[:work_id].presence || cached_metadata[:work_id]
    @source_work_ids = [ *Array(params[:source_work_ids]), *Array(cached_metadata[:source_work_ids]) ].compact_blank.uniq
    @title = cached_metadata[:title].presence || params[:title]
    @author = cached_metadata[:author].presence || params[:author]
    @cover_url = cached_metadata[:cover_url].presence || params[:cover_url]
    @first_publish_year = cached_metadata[:first_publish_year].presence || params[:first_publish_year]
    @description = cached_metadata[:description].presence || params[:description]
    @content_kind = normalized_content_kind(cached_metadata[:content_kind].presence || params[:content_kind])
    @publisher = cached_metadata[:publisher].presence || params[:publisher]
    @page_count = params[:page_count]
    @language = params[:language]
    @genres = params[:genres]
    @issue_number = cached_metadata[:issue_number].presence || params[:issue_number]
    @release_date = cached_metadata[:release_date].presence || params[:release_date]
    @series = cached_metadata[:series].presence || params[:series]
    @series_position = cached_metadata[:series_position].presence || params[:series_position]
    @collection_source = cached_metadata[:collection_source].presence || params[:collection_source]
    @collection_id = cached_metadata[:collection_id].presence || params[:collection_id]
    @collection_title = cached_metadata[:collection_title].presence || params[:collection_title]
    @modal = params[:modal] == "1"
    @metadata_source_name, @metadata_source_url = metadata_source_for(@work_id)
    @details_enrichment_attempted = false
    @details_enrichment_loaded = false

    enrich_details_from_source
    @content_kind = ContentKinds.resolve(
      @content_kind,
      source_work_ids: [ @work_id, *@source_work_ids ],
      collection_source: @collection_source,
      default: ContentKinds::BOOK
    )
    @available_book_types = RequestOptionPolicy.book_types_for(@content_kind)
    @collection_entries = collection_entries

    redirect_to search_path, alert: "Missing title information" if @work_id.blank? || @title.blank?
  end

  def close_modal
    render :close_modal, layout: false
  end

  def url_options
    options = super
    return options if @live_script_name.blank?

    options.merge(script_name: @live_script_name)
  end

  private

  def details_handoff_metadata
    metadata = RequestMetadataHandoff.fetch(user: Current.user, token: params[:metadata_token])
    return metadata if params[:work_id].blank? || metadata[:work_id] == params[:work_id]

    {}
  end

  def redirect_legacy_details_handoff?
    return false if params[:metadata_token].present? || params[:description].blank?

    metadata = params.permit(
      :work_id, :title, :author, :cover_url, :first_publish_year,
      :description, :publisher, :content_kind, :issue_number,
      :release_date, :series, :series_position, :request_scope,
      :collection_source, :collection_id, :collection_title,
      source_work_ids: []
    ).to_h.symbolize_keys
    navigation_params = RequestMetadataHandoff.params_for(user: Current.user, metadata: metadata)
    navigation_params[:modal] = params[:modal] if params[:modal].present?
    redirect_to search_details_path(navigation_params)
    true
  end

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
    ContentKinds.normalize(value, default: nil)
  end

  def enrich_details_from_source
    return if @work_id.blank?

    @details_enrichment_loaded = enrich_details_for_source(@work_id) || @details_enrichment_loaded
    return if essential_details_present?

    alternate_work_ids = @source_work_ids.reject do |work_id|
      Book.parse_work_id(work_id).first == Book.parse_work_id(@work_id).first
    end
    metadata = BookMetadataLookupService.call(alternate_work_ids, fallback: details_lookup_fallback)
    apply_lookup_metadata(metadata)
    @details_enrichment_loaded ||= metadata.present?
  end

  def essential_details_present?
    @title.present? && @author.present? && @description.present?
  end

  def details_lookup_fallback
    {
      title: @title,
      author: @author,
      cover_url: @cover_url,
      year: @first_publish_year,
      description: @description,
      publisher: @publisher,
      content_kind: @content_kind,
      issue_number: @issue_number,
      release_date: @release_date,
      series: @series,
      series_position: @series_position,
      collection_source: @collection_source,
      collection_id: @collection_id,
      collection_title: @collection_title
    }
  end

  def apply_lookup_metadata(metadata)
    @title = @title.presence || metadata[:title]
    @author = @author.presence || metadata[:author]
    @cover_url = @cover_url.presence || metadata[:cover_url]
    @first_publish_year = @first_publish_year.presence || metadata[:year]
    @description = @description.presence || metadata[:description]
    @publisher = @publisher.presence || metadata[:publisher]
    @content_kind = @content_kind.presence || metadata[:content_kind]
    @issue_number = @issue_number.presence || metadata[:issue_number]
    @release_date = @release_date.presence || metadata[:release_date]
    @series = @series.presence || metadata[:series]
    @series_position = @series_position.presence || metadata[:series_position]
    @collection_source = @collection_source.presence || metadata[:collection_source]
    @collection_id = @collection_id.presence || metadata[:collection_id]
    @collection_title = @collection_title.presence || metadata[:collection_title]
  end

  def enrich_details_for_source(work_id)
    source, source_id = Book.parse_work_id(work_id)
    case source
    when "hardcover"
      enrich_hardcover_details(source_id)
    when "comic_vine"
      enrich_comic_vine_details(source_id)
    when "google_books"
      enrich_google_books_details(source_id)
    when "openlibrary"
      enrich_openlibrary_details(source_id)
    else
      false
    end
  rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error => e
    Rails.logger.warn("[SearchController] Details enrichment failed for #{work_id}: #{e.message}")
    false
  end

  def enrich_hardcover_details(source_id)
    return false unless HardcoverClient.configured?

    @details_enrichment_attempted = true
    details = HardcoverClient.book(source_id)
    @title = @title.presence || details.title
    @author = @author.presence || details.author
    @cover_url = @cover_url.presence || details.cover_url
    @first_publish_year = @first_publish_year.presence || details.release_year
    @description = @description.presence || details.description
    @series = @series.presence || details.series_name
    @series_position = @series_position.presence || details.series_position
    @page_count = @page_count.presence || details.pages
    @genres = @genres.presence || Array(details.genres).compact_blank.join(", ")

    return true if details.series_id.blank? || details.series_name.blank?

    @collection_source = @collection_source.presence || "hardcover"
    @collection_id = @collection_id.presence || details.series_id
    @collection_title = @collection_title.presence || details.series_name
    true
  end

  def enrich_comic_vine_details(source_id)
    return false unless ComicVineClient.configured?

    @details_enrichment_attempted = true
    details = ComicVineClient.details(source_id, content_kind: @content_kind)
    return false unless details

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
    true
  end

  def enrich_google_books_details(source_id)
    return false unless GoogleBooksClient.configured?

    @details_enrichment_attempted = true
    details = GoogleBooksClient.book(source_id)
    @title = @title.presence || details.title
    @author = @author.presence || details.author
    @cover_url = @cover_url.presence || details.cover_url
    @first_publish_year = @first_publish_year.presence || details.release_year
    @description = @description.presence || details.description
    @publisher = @publisher.presence || details.publisher
    @page_count = @page_count.presence || details.page_count
    @language = @language.presence || details.language
    @genres = @genres.presence || Array(details.categories).compact_blank.join(", ")
    true
  end

  def enrich_openlibrary_details(source_id)
    return false unless OpenLibraryClient.configured?

    @details_enrichment_attempted = true
    details = OpenLibraryClient.work(source_id)
    @title = @title.presence || details.title
    @cover_url = @cover_url.presence || details.cover_url(size: :l)
    @first_publish_year = @first_publish_year.presence || parse_year(details.first_publish_date)
    @description = @description.presence || details.description
    @genres = @genres.presence || Array(details.subjects).compact_blank.first(5).join(", ")
    true
  end

  def metadata_source_for(work_id)
    return [ nil, nil ] if work_id.blank?

    book = Book.new
    book.assign_work_id(work_id)
    [ book.metadata_source_name, book.metadata_source_url ]
  end

  def parse_year(value)
    return nil if value.blank?

    match = value.to_s.match(/\b(1[89]\d{2}|20[0-2]\d)\b/)
    match && match[1]
  end

  CollectionEntry = Data.define(:item, :status) do
    def requestable?
      status == :available
    end
  end

  # Loads every item in the collection and marks the ones the user already
  # has (acquired or actively requested) so the view can exclude them from
  # the selection by default.
  def collection_entries
    return [] if @collection_source.blank? || @collection_id.blank?

    items = MetadataCollectionService.expand(
      source: @collection_source,
      collection_id: @collection_id,
      collection_title: @collection_title,
      content_kind: @content_kind
    )
    return [] if items.empty?

    lookup = Book.preload_by_work_ids(items.flat_map(&:source_work_ids))
    items.map do |item|
      CollectionEntry.new(item: item, status: collection_item_status(item, lookup))
    end
  rescue MetadataCollectionService::Error, HardcoverClient::Error, ComicVineClient::Error => e
    Rails.logger.warn("[SearchController] Collection items failed for #{@collection_source}:#{@collection_id}: #{e.message}")
    []
  end

  def collection_item_status(item, lookup)
    statuses = @available_book_types.map do |book_type|
      book = Book.find_in_lookup(lookup, item.source_work_ids, book_type: book_type)
      if book.nil?
        :available
      elsif book.acquired?
        :acquired
      elsif book.requests.any?(&:open?)
        # Checked in Ruby so the lookup's preloaded requests are used instead
        # of one query per collection item.
        :requested
      else
        :available
      end
    end

    return :available if statuses.any?(:available)

    statuses.all?(:acquired) ? :acquired : :requested
  end
end
