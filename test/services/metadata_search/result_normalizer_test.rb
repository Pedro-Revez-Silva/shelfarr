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
