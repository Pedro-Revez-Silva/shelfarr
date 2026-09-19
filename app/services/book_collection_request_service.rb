# frozen_string_literal: true

class BookCollectionRequestService
  Result = Data.define(:created_requests, :skipped, :errors)

  def self.call(...)
    new(...).call
  end

  def self.enabled_languages
    value = SettingsService.get(:enabled_languages) || [ "en" ]
    value = JSON.parse(value) if value.is_a?(String)
    Array(value).select { |code| code.is_a?(String) && ReleaseParserService.language_info(code) }.uniq
  rescue JSON::ParserError
    []
  end

  def initialize(collection:, user:, book_types:, whole_series:, membership_ids: [], language: nil)
    @collection = collection
    @user = user
    @book_types = Array(book_types).map(&:to_s).uniq
    @whole_series = ActiveModel::Type::Boolean.new.cast(whole_series)
    @membership_ids = Array(membership_ids).map(&:to_s).uniq
    @language = language.presence || SettingsService.get(:default_language, default: "en")
  end

  def call
    return failure("Choose ebooks, audiobooks, or both.") if @book_types.empty? || (@book_types - %w[ebook audiobook]).any?
    return failure("An active user is required.") unless @user&.persisted? && User.active.exists?(@user.id)
    return failure("Choose an enabled language.") unless self.class.enabled_languages.include?(@language)

    memberships = @collection.collection_memberships.includes(book_work: { books: :requests }).to_a
    if @whole_series
      selected = memberships.reject(&:ambiguous?)
    else
      return failure("Select at least one book.") if @membership_ids.empty?
      return failure("The selection contains books outside this collection.") if (@membership_ids - memberships.map { |item| item.id.to_s }).any?

      selected = memberships.select { |item| @membership_ids.include?(item.id.to_s) }
    end
    return failure("No unambiguous books are selected. Review the individual books.") if selected.empty?

    created = []
    skipped = @whole_series ? memberships.select(&:ambiguous?).map { |item| "#{item.book_work.title}: review the conflicting series position before requesting." } : []
    errors = []
    selected.each do |membership|
      work = membership.book_work
      @book_types.each do |book_type|
        # A different language remains the same work, but cannot silently
        # satisfy this request or overwrite the existing acquired copy.
        copies = work.books.select { |book| book.book_type == book_type }
        owned = copies.select(&:acquired?)
        if owned.any? && owned.none? { |book| book.language == @language }
          errors << "#{work.title} (#{book_type}): a copy exists in another or unknown language. Review it before requesting a replacement."
          next
        end

        result = RequestCreationService.call(
          user: @user, work_id: work.work_id, book_types: [ book_type ], language: @language,
          collection_item: true,
          metadata_attrs: work.metadata_attrs.merge(
            request_scope: "collection", collection_source: @collection.source,
            collection_id: @collection.source_id, collection_title: @collection.title,
            series: @collection.title, series_position: membership.position
          )
        )
        created.concat(result.created_requests)
        if result.created_requests.empty? && DuplicateDetectionService.check(work_id: work.work_id, book_type: book_type).block?
          skipped.concat(result.errors)
        else
          errors.concat(result.errors)
        end
      rescue ActiveRecord::RecordInvalid => e
        errors << "#{work.title} (#{book_type}): #{e.record.errors.full_messages.to_sentence}"
      end
    end
    Result.new(created_requests: created, skipped: skipped, errors: errors)
  end

  private

  def failure(message)
    Result.new(created_requests: [], skipped: [], errors: [ message ])
  end
end
