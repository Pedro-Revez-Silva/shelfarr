# frozen_string_literal: true

module WebPreview
  class BookPage
    FORMATS = Consumer::RequestView::READABLE_TYPES
    SOURCES = MetadataSources::NAMES.keys.freeze
    SOURCE_ID = /\A[A-Za-z0-9_-]{1,64}\z/
    WORK_ID = /\A(?<source>#{SOURCES.join("|")}):(?<id>[A-Za-z0-9_-]{1,64})\z/
    MAX_LINKS = 9
    ID_COLUMNS = { "hardcover" => :hardcover_id, "google_books" => :google_books_id, "comic_vine" => :comic_vine_id, "openlibrary" => :open_library_work_id }.freeze
    COPY_STATUSES = %w[searching not_found].freeze
    ACTIVE_DOWNLOADS = %i[queued downloading paused].freeze
    COVER_STYLES = %w[clay moss slate oat plum stone].freeze
    METADATA_ERRORS = [ HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error, ArgumentError ].freeze

    def self.work_id(source, source_id)
      "#{source}:#{source_id}" if SOURCES.include?(source) && source_id.is_a?(String) && source_id.match?(SOURCE_ID)
    end

    def self.cover_style(key)
      hash = key.to_s.bytes.reduce(0x811c9dc5) { |value, byte| ((value ^ byte) * 0x01000193) & 0xffffffff }
      COVER_STYLES[hash % COVER_STYLES.size]
    end

    def self.path_for(book)
      return nil unless FORMATS.include?(book.book_type)

      match = WORK_ID.match(book.unified_work_id.to_s)
      { source: match[:source], id: match[:id] } if match
    end

    def self.matching_books(ids)
      conditions = ids.map { |id| Book.parse_work_id(id) }.group_by(&:first).filter_map do |source, pairs|
        column = ID_COLUMNS[source]
        Book.where(column => pairs.map(&:last)) if column
      end
      return [] if conditions.empty?

      conditions.reduce(:or).includes(:requests).order(:id).to_a
    end

    def self.choosing_allowed?(request)
      COPY_STATUSES.include?(request.status) && !request.downloads.where(status: ACTIVE_DOWNLOADS).exists?
    end

    def initialize(user:, work_id:, links: [], details: {}, publication: nil)
      @user = user
      @work_id = work_id
      @seeds = [ work_id, *Array(links).map(&:to_s).select { |value| value.match?(WORK_ID) } ].uniq.first(MAX_LINKS)
      @details = details
      @publication = publication
    end

    def work_ids
      @work_ids ||= begin
        linked = self.class.matching_books(@seeds).flat_map { |book| Book.work_ids_for(book) }
        [ *@seeds, *linked.select { |value| value.match?(WORK_ID) } ].uniq.first(MAX_LINKS)
      end
    end

    def representation
      { id: @work_id, also: work_ids.drop(1), **metadata_fields, formats: FORMATS.map { |book_type| format(book_type) } }
    end

    def states
      FORMATS.map { |book_type| { book_type: book_type, state: state(book_type) } }
    end

    def requestable?(book_type)
      state(book_type) == "requestable"
    end

    def metadata
      @metadata ||= local_metadata || handoff_metadata || catalogue_metadata || {}
    end

    private

    def stored_books
      @stored_books ||= self.class.matching_books(work_ids)
    end

    def books_of(book_type)
      stored_books.select { |book| book.book_type == book_type }
    end

    def book_for(book_type)
      candidates = books_of(book_type)
      candidates.find(&:acquired?) || candidates.find { |book| active_request(book) } || candidates.first
    end

    def active_request(book)
      requests = book&.requests.to_a
      latest(requests.select(&:open?)) || latest(requests.select(&:not_found?))
    end

    def latest(requests)
      requests.max_by { |request| [ request.created_at, request.id ] }
    end

    def state(book_type)
      book = book_for(book_type)
      return "in_library" if book&.acquired?

      request = active_request(book)
      return "requestable" unless request

      visible?(request) ? "requested" : "requested_by_someone"
    end

    def format(book_type)
      book = book_for(book_type)
      current = state(book_type)
      {
        book_type: book_type,
        state: current,
        publication: current == "in_library" ? @publication.call(book) : nil,
        request: current == "requested" ? request_fields(active_request(book)) : nil
      }
    end

    def local_metadata
      book = stored_books.select { |found| FORMATS.include?(found.book_type) }.min_by { |found| [ found.acquired? ? 0 : 1, found.id ] }
      return unless book

      { origin: "library", title: book.title, author: book.author.presence, year: book.year, description: book.description.presence, cover_url: book.cover_url }
    end

    def handoff_metadata
      return if @details[:title].blank?

      found = { origin: "catalogue", title: @details[:title], author: @details[:author].presence, year: @details[:year],
        description: @details[:description].presence, cover_url: @details[:cover_url] }
      return found if found[:author] && found[:description]

      (catalogue_metadata || {}).merge(found.compact)
    end

    def catalogue_metadata
      found = BookMetadataLookupService.call(work_ids)
      return if found[:title].blank?

      { origin: "catalogue", title: found[:title], author: found[:author].presence, year: found[:year], description: found[:description].presence, cover_url: found[:cover_url] }
    rescue *METADATA_ERRORS => error
      Rails.logger.warn("[WebPreview::BookPage] Details lookup failed for #{@work_id}: #{error.class}")
      nil
    end

    def metadata_fields
      source, = Book.parse_work_id(@work_id)
      probe = Book.new.tap { |book| book.assign_work_id(@work_id) }
      {
        details: metadata[:origin] || "missing",
        title: metadata[:title].to_s.presence,
        author: metadata[:author],
        year: metadata[:year].to_s.match?(/\A\d{1,4}\z/) ? metadata[:year].to_i : nil,
        description: metadata[:description].to_s.first(4_000).presence,
        cover: { url: Consumer::SafeLink.call(metadata[:cover_url]), style: self.class.cover_style(@work_id) },
        source: { name: MetadataSources.display_name(source), url: probe.metadata_source_url }
      }
    end

    def visible?(request)
      request.user_id == @user.id || @user.admin?
    end

    def request_fields(request)
      view = Consumer::RequestView.new(request).representation
      fields = view.slice(:id, :status, :stage, :attention_needed, :download_percent, :can_cancel, :next_retry_at, :created_at, :updated_at)
        .merge(own: request.user_id == @user.id, choice_needed: request.needs_manual_selection?)
      return fields unless @user.admin?

      fields.merge(requested_by: request.user&.name.to_s, issue: request.issue_description.to_s.first(500).presence, copies: copies(request))
    end

    def copies(request)
      candidates = request.search_results.best_first.to_a
      {
        selectable: self.class.choosing_allowed?(request) && candidates.any?(&:downloadable?),
        can_search_again: request.search_refresh_allowed?,
        candidates: candidates.map { |result| candidate(result) }
      }
    end

    def candidate(result)
      {
        id: result.id.to_s,
        title: result.title.to_s,
        format: (result.primary_extension || result.detected_extensions.first).to_s.upcase.presence,
        size_bytes: result.size_bytes.to_i.positive? ? result.size_bytes : nil,
        language: result.language_display_name,
        source: result.source_display_name,
        state: result.status,
        skipped: result.blocklisted?,
        downloadable: result.downloadable?
      }
    end
  end
end
