# frozen_string_literal: true

require "test_helper"

module MetadataSearch
  class ContentClassifierTest < ActiveSupport::TestCase
    test "normalizes legacy kinds through the canonical content kinds API" do
      assert_equal "graphic", ContentKinds.normalize("comic")
      assert_equal "graphic", ContentKinds.normalize("manga")
      assert_equal "book", ContentKinds.normalize("unknown")
      assert_equal "graphic", ContentKinds.normalize(nil, default: "graphic")
      assert_nil ContentKinds.normalize("unknown", default: nil)
      assert ContentKinds.graphic?("comic")
      assert ContentKinds.graphic?("graphic")
      assert_not ContentKinds.graphic?("book")
    end

    test "resolves Comic Vine identity as graphic regardless of supplied kind" do
      assert_equal "graphic", ContentKinds.resolve("book", source_work_ids: [ "comic_vine:4000-1" ])
      assert_equal "graphic", ContentKinds.resolve(nil, collection_source: "comic_vine")
      assert_equal "book", ContentKinds.resolve(nil, source_work_ids: [ "openlibrary:OL1W" ])
    end

    test "classifies Google graphic categories with strong evidence" do
      result = ContentClassifier.call(
        source: "google_books",
        categories: [ "Fiction / Comics & Graphic Novels / Manga" ]
      )

      assert_equal "graphic", result.content_kind
      assert_equal 90, result.confidence
      assert_equal [ "category:Fiction / Comics & Graphic Novels / Manga" ], result.evidence
    end

    test "classifies Open Library graphic subjects with strong evidence" do
      result = ContentClassifier.call(
        source: "openlibrary",
        subjects: [ "Comic books, strips, etc." ]
      )

      assert_equal "graphic", result.content_kind
      assert_equal 90, result.confidence
      assert_equal [ "subject:Comic books, strips, etc." ], result.evidence
    end

    test "classifies standalone comics metadata from either provider" do
      google = ContentClassifier.call(source: "google_books", categories: [ "Comics" ])
      open_library = ContentClassifier.call(source: "openlibrary", subjects: [ "Comics" ])

      assert_equal "graphic", google.content_kind
      assert_equal 90, google.confidence
      assert_equal "graphic", open_library.content_kind
      assert_equal 90, open_library.confidence
    end

    test "prefers strong provider evidence over a conflicting requested kind" do
      result = ContentClassifier.call(
        source: "google_books",
        categories: [ "Comics & Graphic Novels" ],
        requested_content_kind: "book"
      )

      assert_equal "graphic", result.content_kind
      assert_equal 90, result.confidence
      assert_equal [ "category:Comics & Graphic Novels" ], result.evidence
    end

    test "defaults to book when neither provider nor request supplies evidence" do
      result = ContentClassifier.call(source: "openlibrary", subjects: [ "Fiction" ])

      assert_equal "book", result.content_kind
      assert_equal 10, result.confidence
      assert_equal [ "default:book" ], result.evidence
    end

    test "uses requested legacy kind only as a low confidence fallback" do
      result = ContentClassifier.call(
        source: "google_books",
        categories: [ "Fiction" ],
        requested_content_kind: "manga"
      )

      assert_equal "graphic", result.content_kind
      assert_equal 20, result.confidence
      assert_equal [ "requested_kind:graphic" ], result.evidence
    end

    test "treats Comic Vine as definitive graphic evidence" do
      result = ContentClassifier.call(source: "comic_vine", requested_content_kind: "book")

      assert_equal "graphic", result.content_kind
      assert_equal 100, result.confidence
      assert_equal [ "provider:comic_vine" ], result.evidence
    end
  end
end
