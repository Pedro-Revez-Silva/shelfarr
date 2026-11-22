# frozen_string_literal: true

module WebPreview
  class BookPage
    FORMATS = Consumer::RequestView::READABLE_TYPES
    SOURCES = MetadataSources::NAMES.keys.freeze
    SOURCE_ID = /\A[A-Za-z0-9_-]{1,64}\z/
    WORK_ID = /\A(?<source>#{SOURCES.join("|")}):(?<id>[A-Za-z0-9_-]{1,64})\z/
    MAX_LINKS = 9
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

    def self.choosing_allowed?(request)
      COPY_STATUSES.include?(request.status) && !request.downloads.where(status: ACTIVE_DOWNLOADS).exists?
    end

    def self.choosable?(result)
      result.pending? && result.downloadable?
    end

    def initialize(user:, work_id:, handoff:, publication:)
      @user = user
      @work_id = work_id
      @handoff = handoff[:work_id] == work_id ? handoff : {}
      @publication = publication
    end

    def work_ids
      @work_ids ||= begin
        seeds = [ @work_id, *Array(@handoff[:source_work_ids]).map(&:to_s).select { |value| value.match?(WORK_ID) } ].uniq
        linked = stored_books(Book.preload_by_work_ids(seeds)).flat_map { |book| Book.work_ids_for(book) }
        [ *seeds, *linked.select { |value| value.match?(WORK_ID) } ].uniq.first(MAX_LINKS)
      end
    end

    def representation
      {
        id: @work_id,
        also: work_ids.drop(1),
        **metadata_fields,
        formats: FORMATS.map { |book_type| format(book_type) }
      }
    end

    def metadata
      @metadata ||= local_metadata || handoff_metadata || catalogue_metadata || {}
    end

    def details_origin
      metadata[:origin] || "missing"
    end

    private

    def lookup
      @lookup ||= Book.preload_by_work_ids(work_ids)
    end

    def books
      @books ||= FORMATS.filter_map { |book_type| Book.find_in_lookup(lookup, work_ids, book_type: book_type) }
    end

    def stored_books(found)
      found.values.flat_map(&:values).uniq
    end

    def local_metadata
      book = books.find(&:acquired?) || books.first
      return unless book

      { origin: "library", title: book.title, author: book.author.presence, year: book.year, description: book.description.presence, cover_url: book.cover_url }
    end

    def handoff_metadata
      return if @handoff[:title].blank?

      found = { origin: "catalogue", title: @handoff[:title], author: @handoff[:author].presence, year: @handoff[:first_publish_year],
        description: @handoff[:description].presence, cover_url: @handoff[:cover_url] }
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
        details: details_origin,
        title: metadata[:title].to_s.presence,
        author: metadata[:author],
        year: metadata[:year].to_s.match?(/\A\d{1,4}\z/) ? metadata[:year].to_i : nil,
        description: metadata[:description].to_s.first(4_000).presence,
        cover: { url: Consumer::SafeLink.call(metadata[:cover_url]), style: self.class.cover_style(@work_id) },
        source: { name: MetadataSources.display_name(source), url: probe.metadata_source_url }
      }
    end

    def format(book_type)
      check = DuplicateDetectionService.check(work_id: @work_id, source_work_ids: work_ids.drop(1), book_type: book_type, existing_books_lookup: lookup)
      book = Book.find_in_lookup(lookup, work_ids, book_type: book_type)
      entry = { book_type: book_type, state: "requestable", note: nil, publication: nil, request: nil }
      return entry.merge(state: "in_library", publication: @publication.call(book)) if book&.acquired?

      if check.block? && check.existing_request
        request = check.existing_request
        return visible?(request) ? entry.merge(state: "requested", request: request_fields(request)) : entry.merge(state: "requested_by_someone")
      end

      latest = book&.requests&.reject(&:completed?)&.max_by { |request| [ request.created_at, request.id ] }
      return entry unless latest && visible?(latest)
      return entry.merge(state: "requested", request: request_fields(latest)) if latest.not_found?

      entry.merge(note: check.warn? ? check.message : nil)
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
        selectable: self.class.choosing_allowed?(request) && candidates.any? { |result| self.class.choosable?(result) },
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
        downloadable: self.class.choosable?(result)
      }
    end
  end
end
