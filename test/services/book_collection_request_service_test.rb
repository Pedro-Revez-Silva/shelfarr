require "test_helper"

class BookCollectionRequestServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @collection = BookCollection.create!(source: "hardcover", source_id: "701", title: "Harry Potter")
    7.times do |index|
      work = BookWork.create!(source: "hardcover", source_id: (9201 + index).to_s, title: "Book #{index + 1}", author: "Author")
      @collection.collection_memberships.create!(book_work: work, position: (index + 1).to_s, sort_order: index)
    end
    @language_settings = [ SettingsService.get(:enabled_languages), SettingsService.get(:default_language) ]
    SettingsService.set(:enabled_languages, [ "en", "pt" ])
    SettingsService.set(:default_language, "en")
    clear_enqueued_jobs
  end

  teardown do
    SettingsService.set(:enabled_languages, @language_settings.first)
    SettingsService.set(:default_language, @language_settings.last)
  end

  test "seven underlying works produce fourteen requests and repeated submissions create none" do
    result = request_collection
    assert_equal 14, result.created_requests.length
    assert_empty result.errors
    assert_equal 7, @collection.book_works.count
    assert_equal 14, Book.where(book_work: @collection.book_works).count
    assert result.created_requests.all? { |request| request.request_scope == "collection" && request.collection_id == "701" }

    assert_no_difference [ "Book.count", "Request.count" ] do
      second = request_collection
      assert_empty second.created_requests
      assert_empty second.errors
      assert_equal 14, second.skipped.length
    end
  end

  test "multiple acquired editions count as one satisfied format and audiobook remains requestable" do
    work = @collection.book_works.first
    [ 1997, 2007, 2026 ].each do |year|
      Book.create!(title: work.title, hardcover_id: work.source_id, book_type: :ebook,
        year: year, isbn: "edition-#{year}", file_path: "/ebooks/#{year}.epub")
    end
    # A later pending legacy row must not hide an acquired edition.
    Book.create!(title: work.title, hardcover_id: work.source_id, book_type: :ebook)

    result = request_collection
    assert_equal 13, result.created_requests.size
    assert_equal 1, result.skipped.size
    assert_empty result.errors
    assert_equal [ "audiobook" ], result.created_requests.select { |request| request.book.book_work_id == work.id }.map { |request| request.book.book_type }
  end

  test "overlapping collections and ordinary individual requests share duplicate detection" do
    request_collection
    other = BookCollection.create!(source: "hardcover", source_id: "702", title: "Another series")
    work = @collection.book_works.first
    other.collection_memberships.create!(book_work: work)

    assert_no_difference "Request.count" do
      assert_equal 2, request_collection(collection: other).skipped.length
      result = RequestCreationService.call(user: users(:one), work_id: work.work_id,
        book_types: [ "ebook" ], metadata_attrs: work.metadata_attrs)
      assert_empty result.created_requests
    end
  end

  test "a trusted existing provider alias shares the saved work and format identity" do
    work = @collection.book_works.first
    legacy = Book.create!(title: work.title, book_type: :ebook, hardcover_id: work.source_id,
      open_library_work_id: "OL_COLLECTION_ALIAS")
    result = RequestCreationService.call(user: users(:one), work_id: "openlibrary:OL_COLLECTION_ALIAS",
      book_types: [ "audiobook" ], metadata_attrs: { title: work.title })

    assert_equal 1, result.created_requests.size
    assert_equal work, result.created_requests.first.book.book_work
    assert_equal work.source_id, result.created_requests.first.book.hardcover_id
    assert_equal work, legacy.reload.book_work

    repeated = request_collection(whole_series: false, membership_ids: [ @collection.collection_memberships.first.id ], book_types: [ "audiobook" ])
    assert_empty repeated.created_requests
    assert_equal 1, repeated.skipped.length
  end

  test "identifiers belonging to two saved works are rejected rather than merged" do
    first, second = @collection.book_works.first(2)
    Book.create!(title: first.title, book_type: :ebook, hardcover_id: first.source_id, open_library_work_id: "OL_FIRST_WORK")
    assert_no_difference "Request.count" do
      result = RequestCreationService.call(user: users(:one), work_id: second.work_id,
        source_work_ids: [ "openlibrary:OL_FIRST_WORK" ], book_types: [ "ebook" ], metadata_attrs: second.metadata_attrs)
      assert_empty result.created_requests
      assert_match(/different books/, result.errors.first)
    end
  end

  test "whole series excludes ambiguous positions but explicit selection can request one" do
    @collection.collection_memberships.limit(2).update_all(ambiguous: true, position: "1")
    result = request_collection(book_types: [ "ebook" ])
    assert_equal 5, result.created_requests.length
    assert_equal 2, result.skipped.length
    assert_empty result.errors

    chosen = @collection.collection_memberships.first
    explicit = request_collection(whole_series: false, membership_ids: [ chosen.id ], book_types: [ "ebook" ])
    assert_equal [ chosen.book_work ], explicit.created_requests.map { |request| request.book.book_work }
  end

  test "empty selections invalid formats and foreign members cannot become whole series requests" do
    [ { whole_series: false, membership_ids: [] }, { whole_series: false, membership_ids: [ "99999999" ] },
      { book_types: [] }, { book_types: [ "ebook", "comicbook" ] }, { language: "invented" } ].each do |options|
      assert_no_difference "Request.count" do
        result = request_collection(**options)
        assert_empty result.created_requests
        assert result.errors.any?
      end
    end
  end

  test "acquired copies in another language require review and new copies retain requested language" do
    work = @collection.book_works.first
    Book.create!(title: work.title, hardcover_id: work.source_id, book_type: :ebook, language: "en", file_path: "/ebooks/english.epub")

    result = request_collection(book_types: [ "ebook" ], language: "pt")
    assert_equal 6, result.created_requests.size
    assert_equal 1, result.errors.size
    assert_match(/another or unknown language/, result.errors.first)
    assert result.created_requests.all? { |request| request.language == "pt" && request.book.language == "pt" }
  end

  test "a previously failed unacquired record adopts the newly requested language" do
    work = @collection.book_works.first
    book = Book.create!(title: work.title, hardcover_id: work.source_id, book_type: :ebook, language: "en")
    users(:one).requests.create!(book: book, status: :failed, language: "en")

    result = request_collection(book_types: [ "ebook" ], language: "pt")
    assert_equal 7, result.created_requests.size
    assert_empty result.errors
    assert_equal "pt", book.reload.language
  end

  test "legacy Hardcover collection requests also exclude conflicting positions" do
    items = @collection.collection_memberships.first(3).each_with_index.map do |membership, index|
      work = membership.book_work
      MetadataCollectionService::Item.new(work_id: work.work_id, source_work_ids: [ work.work_id ],
        metadata_attrs: work.metadata_attrs.merge(series_position: index < 2 ? "1" : "2", request_scope: "collection"))
    end
    MetadataCollectionService.stub(:expand, items) do
      result = RequestCreationService.call(user: users(:one), work_id: items.first.work_id, book_types: [ "ebook" ],
        metadata_attrs: { request_scope: "collection", collection_source: "hardcover", collection_id: "701" }, expand_collection: true)
      assert_equal 1, result.created_requests.size
      assert_equal 2, result.warnings.size
      assert_equal items.last.work_id, result.created_requests.first.book.unified_work_id
    end
  end

  test "deleted users cannot request a collection" do
    user = users(:one)
    user.update!(deleted_at: Time.current)
    assert_no_difference "Request.count" do
      assert_match(/active user/, request_collection(user: user).errors.first)
    end
  end

  test "partial validation failure preserves successful requests and retry only fills missing books" do
    broken = @collection.book_works.first
    callback = ->(book) { book.errors.add(:title, "rejected for test") if book.hardcover_id == broken.source_id }
    Book.set_callback(:validation, :after, callback)
    result = request_collection(book_types: [ "ebook" ])
    assert_equal 6, result.created_requests.size
    assert_equal 1, result.errors.size
    Book.skip_callback(:validation, :after, callback)
    callback = nil

    retry_result = request_collection(book_types: [ "ebook" ])
    assert_equal 1, retry_result.created_requests.size
    assert_equal 6, retry_result.skipped.size
    assert_empty retry_result.errors

  ensure
    Book.skip_callback(:validation, :after, callback) if callback
  end

  test "a new Hardcover identifier cannot override a trusted alias of another saved work" do
    work = @collection.book_works.first
    book = Book.create!(title: work.title, hardcover_id: work.source_id,
      open_library_work_id: "OL_SAVED_COLLECTION_WORK", book_type: :ebook)
    unknown_id = "939999"
    assert_not BookWork.exists?(source: "hardcover", source_id: unknown_id)

    assert_no_difference [ "Book.count", "Request.count" ] do
      result = RequestCreationService.call(user: users(:one), work_id: "hardcover:#{unknown_id}",
        source_work_ids: [ "openlibrary:#{book.open_library_work_id}" ], book_types: [ "ebook" ],
        metadata_attrs: { title: "An unrelated book" })

      assert_empty result.created_requests
      assert_match(/different books/, result.errors.sole)
    end
    assert_equal work.source_id, book.reload.hardcover_id
    assert_equal work, book.book_work
  end

  test "an unacquired provider alias cannot hide an acquired copy of the same saved work" do
    work = @collection.book_works.first
    acquired = Book.create!(title: work.title, hardcover_id: work.source_id, book_type: :ebook,
      file_path: "/ebooks/saved-edition.epub")
    alias_copy = Book.create!(title: work.title, hardcover_id: work.source_id,
      open_library_work_id: "OL_PENDING_EDITION_ALIAS", book_type: :ebook)

    assert_no_difference [ "Book.count", "Request.count" ] do
      result = RequestCreationService.call(user: users(:one), work_id: "openlibrary:#{alias_copy.open_library_work_id}",
        book_types: [ "ebook" ], metadata_attrs: work.metadata_attrs)

      assert_empty result.created_requests
      assert_match(/already in your library/, result.errors.sole)
    end
    assert_equal "/ebooks/saved-edition.epub", acquired.reload.file_path
    assert_nil alias_copy.reload.file_path
  end

  test "legacy collection batches report and dispatch committed requests before a later member fails" do
    first, broken = @collection.book_works.order(:id).limit(2)
    members = [ first, broken ].each_with_index.map do |work, index|
      MetadataCollectionService::Item.new(work_id: work.work_id, source_work_ids: [ work.work_id ],
        metadata_attrs: work.metadata_attrs.merge(request_scope: "collection", collection_source: "hardcover",
          collection_id: @collection.source_id, collection_title: @collection.title, series_position: (index + 1).to_s))
    end
    callback = ->(book) { book.errors.add(:title, "rejected for test") if book.hardcover_id == broken.source_id }
    original_immediate_search = SettingsService.get(:immediate_search_enabled)
    SettingsService.set(:immediate_search_enabled, true)
    Book.set_callback(:validation, :after, callback)

    result = nil
    assert_enqueued_jobs 1, only: SearchJob do
      MetadataCollectionService.stub(:expand, members) do
        result = RequestCreationService.call(user: users(:one), work_id: "hardcover:#{@collection.source_id}",
          book_types: [ "ebook" ], expand_collection: true,
          metadata_attrs: { request_scope: "collection", collection_source: "hardcover",
            collection_id: @collection.source_id, collection_title: @collection.title })
      end
    end

    assert_equal [ first ], result.created_requests.map { |request| request.book.book_work }
    assert_equal 1, result.errors.size
    assert_match(/rejected for test/, result.errors.sole)
    assert_enqueued_with(job: SearchJob, args: [ result.created_requests.sole.id ])
    assert_not Book.exists?(hardcover_id: broken.source_id)
  ensure
    Book.skip_callback(:validation, :after, callback) if callback
    SettingsService.set(:immediate_search_enabled, original_immediate_search)
  end

  test "a saved work rolls back both formats if the second format fails validation" do
    work = @collection.book_works.first
    with_rejected_audiobook(work.source_id) do
      assert_no_difference [ "Book.count", "Request.count" ] do
        assert_no_enqueued_jobs only: SearchJob do
          result = RequestCreationService.call(user: users(:one), work_id: work.work_id,
            book_types: %w[ebook audiobook], metadata_attrs: work.metadata_attrs)

          assert_empty result.created_requests
          assert_match(/rejected audiobook for test/, result.errors.sole)
        end
      end
    end
  end

  test "an unlinked work preserves and dispatches the first format if the second format fails validation" do
    open_library_work_id = "OL_STANDALONE_BOOK"

    with_rejected_audiobook(open_library_work_id, attribute: :open_library_work_id) do
      result = nil
      assert_difference [ "Book.count", "Request.count" ], 1 do
        assert_enqueued_jobs 1, only: SearchJob do
          BookMetadataLookupService.stub(:call, {}) do
            result = RequestCreationService.call(user: users(:one), work_id: "openlibrary:#{open_library_work_id}",
              book_types: %w[ebook audiobook], metadata_attrs: { title: "A standalone book" })
          end
        end
      end

      assert_equal [ "ebook" ], result.created_requests.map { |request| request.book.book_type }
      assert_nil result.created_requests.sole.book.book_work_id
      assert_match(/rejected audiobook for test/, result.errors.sole)
      assert_enqueued_with(job: SearchJob, args: [ result.created_requests.sole.id ])
    end
  end

  private

  def with_rejected_audiobook(source_id, attribute: :hardcover_id)
    callback = lambda do |book|
      book.errors.add(:title, "rejected audiobook for test") if book.public_send(attribute) == source_id && book.audiobook?
    end
    original_immediate_search = SettingsService.get(:immediate_search_enabled)
    SettingsService.set(:immediate_search_enabled, true)
    Book.set_callback(:validation, :after, callback)
    yield
  ensure
    Book.skip_callback(:validation, :after, callback)
    SettingsService.set(:immediate_search_enabled, original_immediate_search)
  end

  def request_collection(**overrides)
    BookCollectionRequestService.call(**{
      collection: @collection, user: users(:one), book_types: %w[ebook audiobook],
      whole_series: true, language: "en"
    }.merge(overrides))
  end
end
