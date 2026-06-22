# frozen_string_literal: true

require "test_helper"

module Integrations
  module Telegram
    class SearchResultCacheTest < ActiveSupport::TestCase
      setup do
        @original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        Rails.cache = @original_cache
      end

      test "stores and fetches merged candidate source work ids" do
        candidate = MetadataSearch::Candidate.new(
          canonical_key: "openlibrary:OL123W",
          title: "Dune",
          author: "Frank Herbert",
          year: 1965,
          description: nil,
          cover_url: nil,
          series_name: nil,
          series_position: nil,
          has_ebook: nil,
          has_audiobook: nil,
          sources: [
            { source: "openlibrary", source_id: "OL123W", source_name: "Open Library", source_url: nil, work_id: "openlibrary:OL123W" },
            { source: "google_books", source_id: "gb123", source_name: "Google Books", source_url: nil, work_id: "google_books:gb123" }
          ],
          editions: [],
          confidence: 90
        )

        token = SearchResultCache.store(candidate)
        selection = SearchResultCache.fetch(token)

        assert_equal 32, token.length
        assert_equal "openlibrary:OL123W", selection[:work_id]
        assert_equal %w[openlibrary:OL123W google_books:gb123], selection[:source_work_ids]
        assert_equal "Dune", selection[:metadata_attrs][:title]
      end

      test "callback data stays within telegram limit" do
        data = SearchResultCache.callback_data("a1b2c3d4e5f60718293a4b5c6d7e8f90", "audiobook")

        assert data.bytesize <= 64
        assert_equal "req|a1b2c3d4e5f60718293a4b5c6d7e8f90|audiobook", data
      end
    end
  end
end
