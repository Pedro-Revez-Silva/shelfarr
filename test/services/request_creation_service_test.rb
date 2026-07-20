# frozen_string_literal: true

require "test_helper"

class RequestCreationServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    clear_enqueued_jobs
  end

  test "creates a request with fallback metadata" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_SERVICE_123W",
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Service Book",
          author: "Service Author",
          first_publish_year: 2024
        }
      )

      assert result.success?
      assert_empty result.errors
    end

    request = Request.last
    assert_equal @user, request.user
    assert_equal "Service Book", request.book.title
    assert_equal "Service Author", request.book.author
    assert_equal 2024, request.book.year
  end

  test "normalizes legacy graphic content kinds before persistence" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "comic_vine:4000-legacy-manga",
      book_types: [ "comicbook" ],
      metadata_attrs: { title: "Legacy Manga", content_kind: "manga" }
    )

    assert result.success?
    assert_equal "graphic", result.created_requests.first.book.content_kind
  end

  test "rejects book formats for graphic content" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "comic_vine:4000-invalid-format",
      book_types: [ "ebook" ],
      metadata_attrs: { title: "Invalid Graphic Format", content_kind: "comic" }
    )

    assert_not result.success?
    assert_equal [ "Ebook cannot be requested for Comics & Manga content" ], result.errors
  end

  test "treats Comic Vine identity as authoritative when content kind is missing or forged" do
    [ nil, "book" ].each do |content_kind|
      assert_no_difference [ "Book.count", "Request.count" ] do
        result = RequestCreationService.call(
          user: @user,
          work_id: "comic_vine:4000-source-policy-#{content_kind || 'missing'}",
          book_types: [ "ebook" ],
          metadata_attrs: { title: "Source Policy", content_kind: content_kind }.compact
        )

        assert_not result.success?
        assert_equal [ "Ebook cannot be requested for Comics & Manga content" ], result.errors
      end
    end
  end

  test "evaluates each collection item using its own provider identity" do
    item = RequestCreationService::RequestInput.new(
      work_id: "comic_vine:4000-child-source-policy",
      source_work_ids: [],
      metadata_attrs: {
        title: "Graphic Child",
        content_kind: "book",
        request_scope: "collection",
        collection_source: "hardcover",
        collection_id: "parent-series"
      }
    )

    MetadataCollectionService.stub(:expand, [ item ]) do
      assert_no_difference [ "Book.count", "Request.count" ] do
        result = RequestCreationService.call(
          user: @user,
          work_id: "hardcover:parent-series",
          book_types: [ "ebook" ],
          metadata_attrs: {
            title: "Book Parent",
            content_kind: "book",
            request_scope: "collection",
            collection_source: "hardcover",
            collection_id: "parent-series"
          },
          expand_collection: true
        )

        assert_not result.success?
        assert_equal [ "Graphic Child: Ebook cannot be requested for Comics & Manga content" ], result.errors
      end
    end
  end

  test "rejects graphic formats for book content" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_INVALID_FORMAT",
      book_types: [ "comicbook" ],
      metadata_attrs: { title: "Invalid Book Format", content_kind: "book" }
    )

    assert_not result.success?
    assert_equal [ "Comics & Manga cannot be requested for book content" ], result.errors
  end

  test "blocks duplicate active requests" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_EBOOK_1",
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "The Pending Ebook"
      }
    )

    assert_not result.success?
    assert_includes result.errors.join, "already has an active request"
  end

  test "enqueues search when auto approve applies to non-admin user" do
    SettingsService.set(:auto_approve_requests, true)

    assert_enqueued_with(job: SearchJob) do
      RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_AUTO_SERVICE_123W",
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Auto Service Book"
        }
      )
    end
  end

  test "stores request origin metadata" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_ORIGIN_SERVICE_123W",
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Origin Service Book"
      },
      origin: {
        created_via: "telegram",
        external_source: "telegram",
        external_user_id: "42",
        external_chat_id: "-100123"
      }
    )

    assert result.success?
    request = result.created_requests.first
    assert_equal "telegram", request.created_via
    assert_equal "telegram", request.external_source
    assert_equal "42", request.external_user_id
    assert_equal "-100123", request.external_chat_id
  end

  test "reports request validation errors with the title and format" do
    assert_no_difference "Request.count" do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_INVALID_ORIGIN",
        book_types: [ "ebook" ],
        metadata_attrs: { title: "Invalid Origin" },
        origin: { created_via: "invalid_origin" }
      )

      assert_not result.success?
      assert_includes result.errors.join, "Invalid Origin Ebook"
      assert_includes result.errors.join, "Created via is not included in the list"
    end
  end

  test "stores all candidate source identifiers on created book" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_MULTI_SOURCE_W",
      source_work_ids: [ "openlibrary:OL_MULTI_SOURCE_W", "google_books:gb-multi-source" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Multi Source Book",
        author: "Source Author"
      }
    )

    assert result.success?
    book = result.created_requests.first.book
    assert_equal "OL_MULTI_SOURCE_W", book.open_library_work_id
    assert_equal "gb-multi-source", book.google_books_id
  end

  test "backfills description from an alternate candidate source" do
    primary = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_AGGREGATED_W",
      title: "Aggregated Book",
      author: nil,
      description: nil,
      year: 2026,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )
    alternate = primary.with(
      source: "google_books",
      source_id: "gb-aggregated",
      description: "Description supplied by the alternate provider"
    )
    lookup = lambda do |work_id|
      work_id == "openlibrary:OL_AGGREGATED_W" ? primary : alternate
    end

    result = MetadataService.stub(:book_details, lookup) do
      RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_AGGREGATED_W",
        source_work_ids: [ "google_books:gb-aggregated" ],
        book_types: [ "ebook" ],
        metadata_attrs: { title: "Aggregated Book" }
      )
    end

    assert result.success?
    assert_equal "Description supplied by the alternate provider", result.created_requests.first.book.description
  end

  test "keeps at most one identifier per supported metadata provider" do
    result = MetadataService.stub(:book_details, nil) do
      RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_BOUNDED_W",
        source_work_ids: [
          "openlibrary:OL_IGNORED_W",
          "google_books:gb-first",
          "google_books:gb-ignored",
          "hardcover:123",
          "comic_vine:4000-123",
          "unsupported:ignored"
        ],
        book_types: [ "comicbook" ],
        metadata_attrs: {
          title: "Bounded Sources",
          author: "Bounded Author",
          description: "Bounded description"
        }
      )
    end

    assert result.success?
    book = result.created_requests.first.book
    assert_equal "OL_BOUNDED_W", book.open_library_work_id
    assert_equal "gb-first", book.google_books_id
    assert_equal "123", book.hardcover_id
    assert_equal "4000-123", book.comic_vine_id
  end

  test "persists newly assigned source ids on reused book with complete metadata" do
    book = Book.create!(
      title: "Existing Google Book",
      author: "Existing Author",
      book_type: :ebook,
      google_books_id: "gb-existing",
      year: 2020,
      description: "Known description",
      cover_url: "https://example.com/cover.jpg",
      metadata_source: "google_books"
    )

    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_NEW_SOURCE_W",
      source_work_ids: [ "google_books:gb-existing", "hardcover:123" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Existing Google Book"
      }
    )

    assert result.success?
    book.reload
    assert_equal "gb-existing", book.google_books_id
    assert_equal "123", book.hardcover_id
    assert_equal "OL_NEW_SOURCE_W", book.open_library_work_id
  end

  test "reuses existing book matched only via alternate source identifier" do
    book = Book.create!(
      title: "Existing Google Book",
      book_type: :ebook,
      google_books_id: "gb-existing"
    )

    assert_no_difference "Book.count" do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_NEW_SOURCE_W",
        source_work_ids: [ "google_books:gb-existing" ],
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Existing Google Book"
        }
      )

      assert result.success?
      assert_equal book, result.created_requests.first.book
    end
  end

  test "blocks duplicate using alternate source identifier" do
    book = Book.create!(
      title: "Existing Google Book",
      book_type: :ebook,
      google_books_id: "gb-existing"
    )
    Request.create!(book: book, user: @user, status: :pending)

    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_NEW_SOURCE_W",
      source_work_ids: [ "google_books:gb-existing" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Existing Google Book"
      }
    )

    assert_not result.success?
    assert_includes result.errors.join, "already has an active request"
  end

  test "collection request expands into per item requests" do
    items = [
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-101",
        source_work_ids: [ "comic_vine:4000-101" ],
        metadata_attrs: {
          title: "Saga - #1",
          author: "Writer One",
          content_kind: "comic",
          issue_number: "1",
          series: "Saga",
          series_position: "1",
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      ),
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-102",
        source_work_ids: [ "comic_vine:4000-102" ],
        metadata_attrs: {
          title: "Saga - #2",
          author: "Writer One",
          content_kind: "comic",
          issue_number: "2",
          series: "Saga",
          series_position: "2",
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      )
    ]

    MetadataService.stub(:book_details, ->(*) { raise "unexpected metadata detail lookup" }) do
      ComicVineClient.stub(:configured?, false) do
        MetadataCollectionService.stub(:expand, items) do
          assert_difference [ "Book.count", "Request.count" ], 2 do
            result = RequestCreationService.call(
              user: @user,
              work_id: "comic_vine:4050-99",
              book_types: [ "comicbook" ],
              metadata_attrs: {
                title: "Saga",
                content_kind: "comic",
                request_scope: "collection",
                collection_source: "comic_vine",
                collection_id: "4050-99",
                collection_title: "Saga"
              },
              expand_collection: true
            )

            assert result.success?
            assert_empty result.errors
            assert_equal 2, result.created_requests.size
          end
        end
      end
    end

    requests = Request.order(id: :desc).limit(2).to_a
    assert requests.all? { |request| request.request_scope == "collection" }
    assert_equal [ "4000-102", "4000-101" ], requests.map { |request| request.book.comic_vine_id }
    assert_equal [ "Saga", "Saga" ], requests.map(&:collection_title)
    assert requests.all? { |request| request.book.content_graphic? }
  end

  test "collection request enqueues background expansion instead of expanding inline" do
    ComicVineClient.stub(:configured?, true) do
      assert_no_difference [ "Book.count", "Request.count" ] do
        assert_enqueued_with(job: CollectionRequestExpansionJob) do
          result = RequestCreationService.call(
            user: @user,
            work_id: "comic_vine:4050-99",
            book_types: [ "comicbook" ],
            metadata_attrs: {
              title: "Saga",
              content_kind: "comic",
              request_scope: "collection",
              collection_source: "comic_vine",
              collection_id: "4050-99",
              collection_title: "Saga"
            },
            collection_item_ids: [ "comic_vine:4000-101", "comic_vine:4000-102" ]
          )

          assert result.queued?
          assert result.success?
          assert_empty result.errors
          assert_empty result.created_requests
        end
      end
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal [ "comic_vine:4000-101", "comic_vine:4000-102" ], job_args["collection_item_ids"]
    assert_equal "graphic", job_args.dig("metadata_attrs", "content_kind")
  end

  test "collection request only creates requests for the selected items" do
    items = [
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-101",
        source_work_ids: [ "comic_vine:4000-101" ],
        metadata_attrs: { title: "Saga - #1", content_kind: "comic", request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99", collection_title: "Saga" }
      ),
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-102",
        source_work_ids: [ "comic_vine:4000-102" ],
        metadata_attrs: { title: "Saga - #2", content_kind: "comic", request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99", collection_title: "Saga" }
      )
    ]

    ComicVineClient.stub(:configured?, false) do
      MetadataCollectionService.stub(:expand, items) do
        assert_difference [ "Book.count", "Request.count" ], 1 do
          result = RequestCreationService.call(
            user: @user,
            work_id: "comic_vine:4050-99",
            book_types: [ "comicbook" ],
            metadata_attrs: {
              title: "Saga",
              content_kind: "comic",
              request_scope: "collection",
              collection_source: "comic_vine",
              collection_id: "4050-99",
              collection_title: "Saga"
            },
            collection_item_ids: [ "comic_vine:4000-102" ],
            expand_collection: true
          )

          assert result.success?
          assert_equal 1, result.created_requests.size
        end
      end
    end

    assert_equal "4000-102", Request.last.book.comic_vine_id
  end

  test "collection request fails when no selected items remain after expansion" do
    items = [
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-101",
        source_work_ids: [ "comic_vine:4000-101" ],
        metadata_attrs: { title: "Saga - #1", request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99" }
      )
    ]

    MetadataCollectionService.stub(:expand, items) do
      result = RequestCreationService.call(
        user: @user,
        work_id: "comic_vine:4050-99",
        book_types: [ "comicbook" ],
        metadata_attrs: { title: "Saga", request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99" },
        collection_item_ids: [ "comic_vine:4000-999" ],
        expand_collection: true
      )

      assert_not result.success?
      assert_includes result.errors.join, "did not contain any requestable items"
    end
  end

  test "collection request fails fast when the collection provider is not configured" do
    ComicVineClient.stub(:configured?, false) do
      assert_no_enqueued_jobs only: CollectionRequestExpansionJob do
        result = RequestCreationService.call(
          user: @user,
          work_id: "comic_vine:4050-99",
          book_types: [ "comicbook" ],
          metadata_attrs: {
            title: "Saga",
            request_scope: "collection",
            collection_source: "comic_vine",
            collection_id: "4050-99"
          }
        )

        assert_not result.success?
        assert_includes result.errors.join, "Comic Vine is not configured"
      end
    end
  end

  test "collection request reports unsupported collection source" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "google_books:gb-collection",
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Collection",
        request_scope: "collection",
        collection_source: "google_books",
        collection_id: "shelf-1"
      }
    )

    assert_not result.success?
    assert_includes result.errors.join, "Collection requests are not supported"
  end
end
