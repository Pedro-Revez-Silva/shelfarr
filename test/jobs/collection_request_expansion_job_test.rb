# frozen_string_literal: true

require "test_helper"

class CollectionRequestExpansionJobTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
  end

  test "expands the collection and creates requests for each item" do
    items = [
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-201",
        source_work_ids: [ "comic_vine:4000-201" ],
        metadata_attrs: {
          title: "Saga - #1",
          content_kind: "comic",
          issue_number: "1",
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      ),
      RequestCreationService::RequestInput.new(
        work_id: "comic_vine:4000-202",
        source_work_ids: [ "comic_vine:4000-202" ],
        metadata_attrs: {
          title: "Saga - #2",
          content_kind: "comic",
          issue_number: "2",
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      )
    ]

    MetadataCollectionService.stub(:expand, items) do
      assert_difference [ "Book.count", "Request.count" ], 2 do
        CollectionRequestExpansionJob.perform_now(
          user_id: @user.id,
          work_id: "comic_vine:4050-99",
          book_types: [ "comicbook" ],
          metadata_attrs: {
            title: "Saga",
            content_kind: "comic",
            request_scope: "collection",
            collection_source: "comic_vine",
            collection_id: "4050-99",
            collection_title: "Saga"
          }
        )
      end
    end

    requests = Request.order(id: :desc).limit(2).to_a
    assert requests.all? { |request| request.request_scope == "collection" }
    assert_equal [ "4000-202", "4000-201" ], requests.map { |request| request.book.comic_vine_id }
  end

  test "skips silently when the user no longer exists" do
    expand_called = false

    MetadataCollectionService.stub(:expand, ->(**) { expand_called = true; [] }) do
      assert_no_difference [ "Book.count", "Request.count" ] do
        CollectionRequestExpansionJob.perform_now(
          user_id: -1,
          work_id: "comic_vine:4050-99",
          book_types: [ "comicbook" ],
          metadata_attrs: { request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99" }
        )
      end
    end

    assert_not expand_called
  end

  test "enqueues a retry when collection expansion fails" do
    MetadataCollectionService.stub(:expand, ->(**) { raise MetadataCollectionService::Error, "Comic Vine down" }) do
      assert_enqueued_with(job: CollectionRequestExpansionJob) do
        CollectionRequestExpansionJob.perform_now(
          user_id: @user.id,
          work_id: "comic_vine:4050-99",
          book_types: [ "comicbook" ],
          metadata_attrs: { title: "Saga", request_scope: "collection", collection_source: "comic_vine", collection_id: "4050-99" }
        )
      end
    end
  end
end
