# frozen_string_literal: true

class RequestCreationService
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

    created_requests = []
    warnings = []
    errors = []
    existing_books_lookup = Book.preload_by_work_ids(source_work_ids)

    book_types.each do |book_type|
      duplicate_check = DuplicateDetectionService.check(
        work_id: work_id,
        source_work_ids: source_work_ids,
        book_type: book_type,
        existing_books_lookup: existing_books_lookup
      )

      if duplicate_check.block?
        errors << "#{book_type.titleize}: #{duplicate_check.message}"
        next
      end

      warnings << duplicate_check.message if duplicate_check.warn?

      book = find_or_create_book_for_source(book_type, existing_books_lookup: existing_books_lookup)
      request = build_request(book)

      if request.save
        after_create(request)
        created_requests << request
      else
        errors << "#{book_type.titleize}: #{request.errors.full_messages.join(', ')}"
      end
    end

    Result.new(created_requests: created_requests, warnings: warnings.compact, errors: errors)
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

  def find_or_create_book_for_source(book_type, existing_books_lookup:)
    book = Book.find_in_lookup(existing_books_lookup, source_work_ids, book_type: book_type)
    book ||= Book.find_or_initialize_by_work_id(work_id, book_type: book_type)
    source_work_ids.each { |source_work_id| book.assign_work_id(source_work_id) }
    BookMetadataBackfillService.apply!(
      book,
      work_id: work_id,
      fallback_attrs: fallback_attrs
    )

    book
  end

  def fallback_attrs
    attrs = metadata_attrs.slice(
      :title,
      :author,
      :cover_url,
      :year,
      :first_publish_year,
      :description,
      :series,
      :series_position
    )
    attrs[:year] ||= attrs.delete(:first_publish_year)
    attrs
  end

  def build_request(book)
    user.requests.build(book: book, status: :pending).tap do |request|
      request.notes = notes if notes.present?
      request.language = language if language.present?
      request.created_via = origin.fetch(:created_via, "web")
      request.external_source = origin[:external_source]
      request.external_user_id = origin[:external_user_id]
      request.external_chat_id = origin[:external_chat_id]
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
