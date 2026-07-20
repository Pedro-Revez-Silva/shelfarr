# frozen_string_literal: true

class RequestCreationService
  RequestInput = Data.define(:work_id, :source_work_ids, :metadata_attrs)

  Result = Data.define(:created_requests, :warnings, :errors, :queued) do
    def initialize(created_requests:, warnings:, errors:, queued: false)
      super
    end

    def success?
      queued || created_requests.any?
    end

    def queued?
      queued
    end
  end

  class << self
    def call(...)
      new(...).call
    end
  end

  def initialize(user:, work_id:, book_types:, metadata_attrs: {}, notes: nil, language: nil, origin: {}, source_work_ids: nil, collection_item_ids: nil, expand_collection: false)
    @user = user
    @work_id = work_id.to_s.strip
    @source_work_ids = BookMetadataLookupService.normalize_work_ids([ @work_id, *Array(source_work_ids) ])
    @source_work_ids = [ @work_id ] if @source_work_ids.empty? && @work_id.present?
    @book_types = normalize_book_types(book_types)
    @metadata_attrs = normalize_metadata_attrs(metadata_attrs)
    @notes = notes
    @language = language
    @origin = origin.to_h.symbolize_keys
    @collection_item_ids = Array(collection_item_ids).compact_blank.map(&:to_s).uniq
    @expand_collection = expand_collection
  end

  def call
    return failure("Missing required information") if work_id.blank? || book_types.empty?
    return failure(incompatible_book_types_error) unless RequestOptionPolicy.permitted_book_types?(book_types, metadata_attrs[:content_kind])
    return enqueue_collection_expansion if collection_request? && !expand_collection?

    request_inputs = build_request_inputs
    return failure("Collection did not contain any requestable items") if request_inputs.empty?

    created_requests = []
    warnings = []
    errors = []
    existing_books_lookup = Book.preload_by_work_ids(request_inputs.flat_map(&:source_work_ids))

    request_inputs.each do |input|
      unless RequestOptionPolicy.permitted_book_types?(book_types, input.metadata_attrs[:content_kind])
        errors << "#{input.metadata_attrs[:title].presence || input.work_id}: #{incompatible_book_types_error(input.metadata_attrs[:content_kind])}"
        next
      end

      book_types.each do |book_type|
        duplicate_check = DuplicateDetectionService.check(
          work_id: input.work_id,
          source_work_ids: input.source_work_ids,
          book_type: book_type,
          existing_books_lookup: existing_books_lookup
        )

        if duplicate_check.block?
          errors << "#{input.metadata_attrs[:title].presence || input.work_id} #{RequestOptionPolicy.book_type_label(book_type)}: #{duplicate_check.message}"
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
          errors << "#{input.metadata_attrs[:title].presence || input.work_id} #{RequestOptionPolicy.book_type_label(book_type)}: #{request.errors.full_messages.join(', ')}"
        end
      end
    end

    Result.new(created_requests: created_requests, warnings: warnings.compact, errors: errors)
  rescue MetadataCollectionService::Error => e
    # In the background-expansion context the job's retry policy owns the error.
    raise if expand_collection?

    failure(e.message)
  end

  private

  attr_reader :user, :work_id, :source_work_ids, :book_types, :metadata_attrs, :notes, :language, :origin, :collection_item_ids

  def failure(message)
    Result.new(created_requests: [], warnings: [], errors: [ message ])
  end

  def normalize_book_types(value)
    Array(value).flatten.filter_map do |book_type|
      normalized = book_type.to_s.strip
      normalized if Book.book_types.key?(normalized)
    end.uniq
  end

  def normalize_metadata_attrs(attrs, fallback_content_kind: nil, source_ids: source_work_ids)
    attrs.to_h.symbolize_keys.tap do |normalized_attrs|
      normalized_attrs[:content_kind] = ContentKinds.resolve(
        normalized_attrs[:content_kind].presence || fallback_content_kind,
        source_work_ids: source_ids,
        collection_source: normalized_attrs[:collection_source],
        default: ContentKinds::BOOK
      )
    end
  end

  def incompatible_book_types_error(content_kind = metadata_attrs[:content_kind])
    incompatible_types = RequestOptionPolicy.incompatible_book_types(book_types, content_kind)
    labels = incompatible_types.map { |book_type| RequestOptionPolicy.book_type_label(book_type) }
    "#{labels.to_sentence} cannot be requested for #{RequestOptionPolicy.content_kind_label(content_kind)} content"
  end

  def build_request_inputs
    if collection_request?
      items = MetadataCollectionService.expand(
        source: metadata_attrs[:collection_source],
        collection_id: metadata_attrs[:collection_id],
        collection_title: metadata_attrs[:collection_title],
        content_kind: metadata_attrs[:content_kind]
      )
      # An explicit selection restricts the request to the items the user
      # ticked in the collection view; without one the whole collection is
      # requested (API compatibility).
      items = items.select { |item| collection_item_ids.include?(item.work_id) } if collection_item_ids.any?
      items.map do |item|
        RequestInput.new(
          work_id: item.work_id,
          source_work_ids: item.source_work_ids,
          metadata_attrs: normalize_metadata_attrs(
            item.metadata_attrs,
            fallback_content_kind: metadata_attrs[:content_kind],
            source_ids: [ item.work_id, *Array(item.source_work_ids) ]
          )
        )
      end
    else
      [ RequestInput.new(work_id: work_id, source_work_ids: source_work_ids, metadata_attrs: metadata_attrs) ]
    end
  end

  def collection_request?
    metadata_attrs[:request_scope].to_s == "collection"
  end

  def expand_collection?
    @expand_collection
  end

  # Expanding a collection can create hundreds of requests, so it must not run
  # inside the web request. Validate what we can cheaply, then hand the
  # expansion to a background job that paginates through the collection.
  def enqueue_collection_expansion
    MetadataCollectionService.validate!(
      source: metadata_attrs[:collection_source],
      collection_id: metadata_attrs[:collection_id]
    )

    CollectionRequestExpansionJob.perform_later(
      user_id: user.id,
      work_id: work_id,
      book_types: book_types,
      metadata_attrs: metadata_attrs,
      notes: notes,
      language: language,
      origin: origin,
      source_work_ids: source_work_ids,
      collection_item_ids: collection_item_ids
    )

    Result.new(created_requests: [], warnings: [], errors: [], queued: true)
  end

  def find_or_create_book_for_source(book_type, input:, existing_books_lookup:)
    book = Book.find_in_lookup(existing_books_lookup, input.source_work_ids, book_type: book_type)
    book ||= Book.find_or_initialize_by_work_id(input.work_id, book_type: book_type)
    input.source_work_ids.each { |source_work_id| book.assign_work_id(source_work_id) }
    BookMetadataBackfillService.apply!(
      book,
      work_id: input.work_id,
      source_work_ids: input.source_work_ids,
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
