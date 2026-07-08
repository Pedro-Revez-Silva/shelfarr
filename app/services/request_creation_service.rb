# frozen_string_literal: true

class RequestCreationService
  # Cap collection expansion so one request cannot fan out into an unbounded
  # number of books, requests, notifications, and search jobs.
  MAX_COLLECTION_ITEMS = 100

  RequestInput = Data.define(:work_id, :source_work_ids, :metadata_attrs)

  Result = Data.define(:created_requests, :warnings, :errors) do
    def success?
      created_requests.any?
    end
  end

  class << self
    def call(...)
      new(...).call
    end
  end

  def initialize(user:, work_id:, book_types:, metadata_attrs: {}, notes: nil, language: nil, origin: {}, source_work_ids: nil)
    @user = user
    @work_id = work_id.to_s.strip
    @source_work_ids = [ @work_id, *Array(source_work_ids) ].compact_blank.map(&:to_s).uniq
    @book_types = normalize_book_types(book_types)
    @metadata_attrs = metadata_attrs.to_h.symbolize_keys
    @notes = notes
    @language = language
    @origin = origin.to_h.symbolize_keys
  end

  def call
    return failure("Missing required information") if work_id.blank? || book_types.empty?

    request_inputs = build_request_inputs
    return failure("Collection did not contain any requestable items") if request_inputs.empty?

    created_requests = []
    warnings = []
    warnings << "Collection has more than #{MAX_COLLECTION_ITEMS} items; only the first #{MAX_COLLECTION_ITEMS} were requested" if @collection_truncated
    errors = []
    existing_books_lookup = Book.preload_by_work_ids(request_inputs.flat_map(&:source_work_ids))

    request_inputs.each do |input|
      book_types.each do |book_type|
        duplicate_check = DuplicateDetectionService.check(
          work_id: input.work_id,
          source_work_ids: input.source_work_ids,
          book_type: book_type,
          existing_books_lookup: existing_books_lookup
        )

        if duplicate_check.block?
          errors << "#{input.metadata_attrs[:title].presence || input.work_id} #{book_type.titleize}: #{duplicate_check.message}"
          next
        end

        warnings << duplicate_check.message if duplicate_check.warn?

        book = find_or_create_book_for_source(book_type, input: input, existing_books_lookup: existing_books_lookup)
        request = build_request(book, input.metadata_attrs)

        if request.save
          after_create(request)
          created_requests << request
          input.source_work_ids.each { |source_work_id| existing_books_lookup[source_work_id.to_s][book.book_type] = book }
        else
          errors << "#{input.metadata_attrs[:title].presence || input.work_id} #{book_type.titleize}: #{request.errors.full_messages.join(', ')}"
        end
      end
    end

    Result.new(created_requests: created_requests, warnings: warnings.compact, errors: errors)
  rescue MetadataCollectionService::Error => e
    failure(e.message)
  end

  private

  attr_reader :user, :work_id, :source_work_ids, :book_types, :metadata_attrs, :notes, :language, :origin

  def failure(message)
    Result.new(created_requests: [], warnings: [], errors: [ message ])
  end

  def normalize_book_types(value)
    Array(value).flatten.filter_map do |book_type|
      normalized = book_type.to_s.strip
      normalized if Book.book_types.key?(normalized)
    end.uniq
  end

  def build_request_inputs
    if collection_request?
      items = MetadataCollectionService.expand(
        source: metadata_attrs[:collection_source],
        collection_id: metadata_attrs[:collection_id],
        collection_title: metadata_attrs[:collection_title],
        content_kind: metadata_attrs[:content_kind],
        limit: MAX_COLLECTION_ITEMS + 1
      )
      @collection_truncated = items.size > MAX_COLLECTION_ITEMS
      items.first(MAX_COLLECTION_ITEMS)
    else
      [ RequestInput.new(work_id: work_id, source_work_ids: source_work_ids, metadata_attrs: metadata_attrs) ]
    end
  end

  def collection_request?
    metadata_attrs[:request_scope].to_s == "collection"
  end

  def find_or_create_book_for_source(book_type, input:, existing_books_lookup:)
    book = Book.find_in_lookup(existing_books_lookup, input.source_work_ids, book_type: book_type)
    book ||= Book.find_or_initialize_by_work_id(input.work_id, book_type: book_type)
    input.source_work_ids.each { |source_work_id| book.assign_work_id(source_work_id) }
    BookMetadataBackfillService.apply!(
      book,
      work_id: input.work_id,
      fallback_attrs: fallback_attrs(input.metadata_attrs),
      lookup_details: !collection_request?
    )

    book
  end

  def fallback_attrs(attrs)
    attrs = attrs.slice(
      :title,
      :author,
      :cover_url,
      :year,
      :first_publish_year,
      :description,
      :series,
      :series_position,
      :publisher,
      :content_kind,
      :issue_number,
      :release_date
    )
    attrs[:year] ||= attrs.delete(:first_publish_year)
    attrs
  end

  def build_request(book, attrs)
    user.requests.build(book: book, status: :pending).tap do |request|
      request.notes = notes if notes.present?
      request.language = language if language.present?
      request.created_via = origin.fetch(:created_via, "web")
      request.external_source = origin[:external_source]
      request.external_user_id = origin[:external_user_id]
      request.external_chat_id = origin[:external_chat_id]
      request.request_scope = attrs[:request_scope].presence || "single"
      request.collection_source = attrs[:collection_source]
      request.collection_id = attrs[:collection_id]
      request.collection_title = attrs[:collection_title]
    end
  end

  def after_create(request)
    ActivityTracker.track(
      "request.created",
      trackable: request,
      user: user,
      details: {
        created_via: request.created_via,
        external_source: request.external_source
      }.compact
    )
    NotificationService.request_created(request)
    SearchJob.perform_later(request.id) if enqueue_search_immediately_for?(request)
  end

  def enqueue_search_immediately_for?(request)
    SettingsService.get(:immediate_search_enabled, default: false) ||
      (!request.user.admin? && SettingsService.auto_approve_requests?)
  end
end
