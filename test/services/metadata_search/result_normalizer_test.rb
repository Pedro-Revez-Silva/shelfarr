# frozen_string_literal: true

require "test_helper"

module MetadataSearch
  class ResultNormalizerTest < ActiveSupport::TestCase
    test "retains Google categories and emits graphic classification evidence" do
      result = GoogleBooksClient::SearchResult.new(
        id: "gb1",
        title: "Saga",
        author: "Brian K. Vaughan",
        description: nil,
        published_date: "2012",
        cover_url: nil,
        has_ebook: false,
        language: "en",
        categories: [ "Comics & Graphic Novels" ]
      )

      normalized = ResultNormalizer.call("google_books", result)

      assert_equal "graphic", normalized.content_kind
      assert_equal "work", normalized.resource_kind
      assert_equal 90, normalized.classification_confidence
      assert_equal [ "category:Comics & Graphic Novels" ], normalized.classification_evidence
      assert_equal [ "Comics & Graphic Novels" ], normalized.categories
      assert_equal false, normalized.has_ebook
    end

    test "retains Open Library subjects and emits graphic classification evidence" do
      result = OpenLibraryClient::SearchResult.new(
        work_id: "OL123W",
        title: "Saga",
        author: "Brian K. Vaughan",
        first_publish_year: 2012,
        cover_id: nil,
        edition_count: 1,
        subjects: [ "Graphic novels" ]
      )

      normalized = ResultNormalizer.call("openlibrary", result)

      assert_equal "graphic", normalized.content_kind
      assert_equal 90, normalized.classification_confidence
      assert_equal [ "subject:Graphic novels" ], normalized.classification_evidence
      assert_equal [ "Graphic novels" ], normalized.subjects
    end

    test "uses requested kind as weak fallback when provider evidence is absent" do
      result = GoogleBooksClient::SearchResult.new(
        id: "gb2",
        title: "Unclassified",
        author: "Author",
        description: nil,
        published_date: nil,
        cover_url: nil,
        has_ebook: true,
        language: "en"
      )

      normalized = ResultNormalizer.call("google_books", result, requested_content_kind: "comic")

      assert_equal "graphic", normalized.content_kind
      assert_equal 20, normalized.classification_confidence
      assert_equal [ "requested_kind:graphic" ], normalized.classification_evidence
    end

    test "supports provider result objects created before classification fields existed" do
      legacy_google_result = Struct.new(
        :id, :title, :author, :first_publish_year, :description, :cover_url, :has_ebook, :language,
        keyword_init: true
      ).new(
        id: "legacy-google",
        title: "Legacy Google Result",
        author: "Author",
        first_publish_year: 2020,
        description: nil,
        cover_url: nil,
        has_ebook: true,
        language: "en"
      )
      legacy_open_library_class = Struct.new(
        :work_id, :title, :author, :first_publish_year,
        keyword_init: true
      ) do
        def cover_url(size:)
          nil
        end
      end
      legacy_open_library_result = legacy_open_library_class.new(
        work_id: "OLLEGACYW",
        title: "Legacy Open Library Result",
        author: "Author",
        first_publish_year: 2021
      )

      google = ResultNormalizer.call("google_books", legacy_google_result)
      open_library = ResultNormalizer.call("openlibrary", legacy_open_library_result)

      assert_equal [], google.categories
      assert_equal [], open_library.subjects
      assert_equal "book", google.content_kind
      assert_equal "book", open_library.content_kind
    end

    test "maps Comic Vine volumes to series and issues to works" do
      volume = comic_vine_result(resource_type: "volume", resource_key: "4050-1")
      issue = comic_vine_result(resource_type: "issue", resource_key: "4000-2")

      normalized_volume = ResultNormalizer.call("comic_vine", volume)
      normalized_issue = ResultNormalizer.call("comic_vine", issue)

      assert_equal "series", normalized_volume.resource_kind
      assert_equal "work", normalized_issue.resource_kind
      assert_equal "graphic", normalized_volume.content_kind
      assert_equal 100, normalized_volume.classification_confidence
      assert_equal [ "provider:comic_vine" ], normalized_volume.classification_evidence

      candidate = Aggregator.call([ normalized_issue ]).first
      assert_predicate candidate, :graphic?
      assert_predicate candidate, :collection?
      assert_equal "comic_vine", candidate.collection_source
      assert_equal "4050-1", candidate.collection_id
      assert_equal "Saga", candidate.collection_title
      assert_equal "1", candidate.issue_number
      assert_equal "2012-03-14", candidate.release_date
    end

    private

    def comic_vine_result(resource_type:, resource_key:)
      ComicVineClient::Result.new(
        id: resource_key.split("-").last,
        resource_type: resource_type,
        resource_key: resource_key,
        title: "Saga",
        description: nil,
        cover_url: nil,
        publisher: "Image",
        creators: "Brian K. Vaughan",
        series_name: "Saga",
        issue_number: resource_type == "issue" ? "1" : nil,
        release_date: "2012-03-14",
        content_kind: "graphic",
        collection_id: "4050-1",
        collection_title: "Saga",
        web_url: nil,
        raw_payload: {}
      )
    end
  end
end
