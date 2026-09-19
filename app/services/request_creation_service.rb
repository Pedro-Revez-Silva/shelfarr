# frozen_string_literal: true

class RequestCreationService
  class IdentityConflictError < StandardError; end

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

  def initialize(user:, work_id:, book_types:, metadata_attrs: {}, notes: nil, language: nil, origin: {}, source_work_ids: nil, collection_item_ids: nil, expand_collection: false, collection_item: false)
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
    @collection_item = collection_item
    @collection_warnings = []
  end

  def call
    return failure("Missing required information") if work_id.blank? || book_types.empty?
    return failure(incompatible_book_types_error) unless RequestOptionPolicy.permitted_book_types?(book_types, metadata_attrs[:content_kind])
    return enqueue_collection_expansion if collection_request? && !expand_collection? && !@collection_item

    request_inputs = build_request_inputs
    return failure("Collection did not contain any requestable items") if request_inputs.empty?

    created_requests = []
    warnings = @collection_warnings.dup
    errors = []
    existing_books_lookup = Book.preload_by_work_ids(request_inputs.flat_map(&:source_work_ids))

    request_inputs.each do |input|
      unless RequestOptionPolicy.permitted_book_types?(book_types, input.metadata_attrs[:content_kind])
        errors << "#{input.metadata_attrs[:title].presence || input.work_id}: #{incompatible_book_types_error(input.metadata_attrs[:content_kind])}"
        next
      end

      input_requests = []
      with_work_identity(input) do |resolved_input, work|
        lookup = work ? Book.preload_by_work_ids(resolved_input.source_work_ids) : existing_books_lookup
        book_types.each do |book_type|
          duplicate_check = DuplicateDetectionService.check(
            work_id: resolved_input.work_id,
            source_work_ids: resolved_input.source_work_ids,
            book_type: book_type,
            existing_books_lookup: lookup
          )

          if duplicate_check.block?
            errors << "#{resolved_input.metadata_attrs[:title].presence || resolved_input.work_id} #{RequestOptionPolicy.book_type_label(book_type)}: #{duplicate_check.message}"
            next
          end

          warnings << duplicate_check.message if duplicate_check.warn?

          book = find_or_create_book_for_source(book_type, input: resolved_input, existing_books_lookup: lookup, lookup_details: work.nil?)
          request = build_request(book, resolved_input.metadata_attrs)

          if request.save
            if work
              input_requests << request
            else
              # The legacy path has no enclosing identity transaction: each
              # successful format is already durable even if the next fails.
              created_requests << request
              after_create(request)
            end
            resolved_input.source_work_ids.each { |source_work_id| lookup[source_work_id.to_s][book.book_type] = book }
          else
            errors << "#{resolved_input.metadata_attrs[:title].presence || resolved_input.work_id} #{RequestOptionPolicy.book_type_label(book_type)}: #{request.errors.full_messages.join(', ')}"
          end
        end
      end
      # Dispatch each committed input before proceeding to the next. A later
      # invalid member must not strand earlier requests or hide their result.
      created_requests.concat(input_requests)
      input_requests.each { |request| after_create(request) }
    rescue IdentityConflictError, ActiveRecord::RecordInvalid => e
      errors << "#{input.metadata_attrs[:title].presence || input.work_id}: #{e.message}"
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
    if collection_request? && !@collection_item
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
      items = unambiguous_collection_items(items) if metadata_attrs[:collection_source] == "hardcover" && collection_item_ids.empty?
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

  def unambiguous_collection_items(items)
    items = items.uniq(&:work_id)
    grouped = items.group_by do |item|
      position = item.metadata_attrs[:series_position].to_s.strip.presence
      next unless position

      begin
        BigDecimal(position).to_s("F")
      rescue ArgumentError
        position.downcase
      end
    end
    ambiguous = grouped.filter_map { |position, members| members if position && members.many? }.flatten
    @collection_warnings.concat(ambiguous.map { |item| "#{item.metadata_attrs[:title]}: review the conflicting series position before requesting." })
    items - ambiguous
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

  def with_work_identity(input)
    matched_books = Book.preload_by_work_ids(input.source_work_ids).values.flat_map(&:values).uniq
    existing_works = BookWork.where(id: matched_books.map(&:book_work_id).compact).to_a
    hardcover_ids = input.source_work_ids.filter_map do |id|
      source, source_id = Book.parse_work_id(id)
      source_id if source == "hardcover"
    end
    hardcover_ids = (hardcover_ids + matched_books.map(&:hardcover_id) + existing_works.map(&:source_id)).compact_blank.uniq
    if hardcover_ids.many? || existing_works.map(&:id).uniq.many?
      raise IdentityConflictError, "These identifiers point to different books. Review the book match before requesting."
    end

    hardcover_id = hardcover_ids.first
    return yield(input, nil) unless hardcover_id&.match?(/\A[1-9]\d*\z/)

    work = BookWork.find_by(source: "hardcover", source_id: hardcover_id)
    unless collection_request?
      # Preserve ordinary request enrichment, but finish network access before
      # entering the admission transaction. Recheck duplicates after locking.
      details = BookMetadataLookupService.call([ "hardcover:#{hardcover_id}", *input.source_work_ids ].uniq, fallback: input.metadata_attrs)
      input = RequestInput.new(work_id: input.work_id, source_work_ids: input.source_work_ids,
        metadata_attrs: input.metadata_attrs.merge(details.compact))
    end
    unless work
      # Establish identity before checking duplicates, including ordinary
      # requests that arrive before the first series import. Existing library
      # aliases are authoritative; title similarity is never an identity join.
      attrs = input.metadata_attrs
      attrs = matched_books.first.attributes.symbolize_keys.merge(attrs.compact_blank) if matched_books.any?
      work = BookWork.create_or_find_by!(source: "hardcover", source_id: hardcover_id) do |record|
        record.assign_attributes(attrs.slice(:title, :author, :cover_url, :description))
        record.release_year = attrs[:first_publish_year] || attrs[:year]
      end
    end

    # Canonical identity must be first in both fields: duplicate detection
    # prepends work_id, and an alias-specific record may be an older empty copy.
    input = RequestInput.new(work_id: work.work_id,
      source_work_ids: ([ work.work_id ] + input.source_work_ids).uniq,
      metadata_attrs: work.metadata_attrs.merge(input.metadata_attrs.compact_blank))

    BookWork.transaction do
      # SELECT FOR UPDATE is ineffective on SQLite. A write before rechecking
      # ownership serializes admission across processes and overlapping series.
      BookWork.where(id: work.id).update_all(updated_at: Time.current)
      work.attach_existing_books!
      yield(input, work)
    end
  end

  def find_or_create_book_for_source(book_type, input:, existing_books_lookup:, lookup_details: true)
    book = Book.find_in_lookup(existing_books_lookup, input.source_work_ids, book_type: book_type)
    book ||= Book.find_or_initialize_by_work_id(input.work_id, book_type: book_type)
    input.source_work_ids.each { |source_work_id| book.assign_work_id(source_work_id) }
    book.language = language.presence || SettingsService.get(:default_language, default: "en") if !book.acquired? && !book.acquisition_reserved?
    BookMetadataBackfillService.apply!(
      book,
      work_id: input.work_id,
      source_work_ids: input.source_work_ids,
      fallback_attrs: fallback_attrs(input.metadata_attrs),
      lookup_details: lookup_details && !collection_request?
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
      :release_date,
      :series_start_year
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
