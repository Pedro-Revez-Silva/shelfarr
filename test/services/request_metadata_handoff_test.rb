# frozen_string_literal: true

require "test_helper"

class RequestMetadataHandoffTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "stores full metadata behind compact identity params" do
    description = "Long description " * 1_000
    metadata = {
      work_id: "openlibrary:OL123W",
      source_work_ids: [ "openlibrary:OL123W", "google_books:gb-123" ],
      title: "Example Book",
      author: "Example Author",
      cover_url: "https://example.com/cover.jpg",
      description: description,
      content_kind: "book"
    }

    params = RequestMetadataHandoff.params_for(user: users(:one), metadata: metadata)

    assert_equal "openlibrary:OL123W", params[:work_id]
    assert_equal metadata[:source_work_ids], params[:source_work_ids]
    assert_equal "book", params[:content_kind]
    assert_match RequestMetadataHandoff::TOKEN_PATTERN, params[:metadata_token]
    assert_empty params.keys & %i[title author cover_url description]
    assert_equal metadata, RequestMetadataHandoff.fetch(user: users(:one), token: params[:metadata_token])
  end

  test "scopes cached metadata to the current user" do
    params = RequestMetadataHandoff.params_for(
      user: users(:one),
      metadata: { work_id: "openlibrary:OL123W", title: "Private handoff" }
    )

    assert_empty RequestMetadataHandoff.fetch(user: users(:two), token: params[:metadata_token])
  end

  test "omits oversized identity values from generated params" do
    oversized_id = "x" * (RequestMetadataHandoff::MAX_IDENTITY_BYTES + 1)

    params = RequestMetadataHandoff.params_for(
      user: users(:one),
      metadata: {
        work_id: "openlibrary:OL123W",
        source_work_ids: [ oversized_id, "google_books:gb-123" ],
        collection_id: oversized_id
      }
    )

    assert_equal [ "google_books:gb-123" ], params[:source_work_ids]
    assert_not params.key?(:collection_id)
  end

  test "rejects malformed tokens without reading arbitrary cache keys" do
    Rails.cache.write("request_metadata_handoff:v1:#{users(:one).id}:../settings", { title: "Wrong" })

    assert_empty RequestMetadataHandoff.fetch(user: users(:one), token: "../settings")
  end
end
