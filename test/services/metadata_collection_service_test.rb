# frozen_string_literal: true

require "test_helper"

class MetadataCollectionServiceTest < ActiveSupport::TestCase
  test "expands comic vine volume issues into request items" do
    comic_issue = ComicVineClient::Result.new(
      id: "123",
      resource_type: "issue",
      resource_key: "4000-123",
      title: "Saga - #1",
      description: "Issue description",
      cover_url: "https://example.com/cover.jpg",
      publisher: "Image",
      creators: "Writer One",
      series_name: "Saga",
      issue_number: "1",
      release_date: "2012-03-14",
      content_kind: "comic",
      collection_id: "4050-99",
      collection_title: "Saga",
      web_url: "https://comicvine.gamespot.com/issue/4000-123/",
      raw_payload: {}
    )

    ComicVineClient.stub(:configured?, true) do
      ComicVineClient.stub(:volume_issues, [ comic_issue ]) do
        items = MetadataCollectionService.expand(source: "comic_vine", collection_id: "4050-99", collection_title: "Saga", content_kind: "comic")

        assert_equal 1, items.size
        assert_equal "comic_vine:4000-123", items.first.work_id
        assert_equal "collection", items.first.metadata_attrs[:request_scope]
        assert_equal "Saga", items.first.metadata_attrs[:collection_title]
        assert_equal "1", items.first.metadata_attrs[:series_position]
      end
    end
  end

  test "raises clear error when comic vine collection expansion is not configured" do
    ComicVineClient.stub(:configured?, false) do
      error = assert_raises MetadataCollectionService::Error do
        MetadataCollectionService.expand(source: "comic_vine", collection_id: "4050-99", collection_title: "Saga", content_kind: "comic")
      end

      assert_equal "Comic Vine is not configured", error.message
    end
  end

  test "expands hardcover series books into request items" do
    series_book = HardcoverClient::SearchResult.new(
      id: "111",
      title: "Series Book One",
      author: "Series Author",
      description: "First book",
      release_year: 2020,
      cover_url: "https://example.com/one.jpg",
      has_audiobook: false,
      has_ebook: false,
      series_name: "Series Name",
      series_position: "1"
    )

    HardcoverClient.stub(:configured?, true) do
      HardcoverClient.stub(:series_books, [ series_book ]) do
        items = MetadataCollectionService.expand(source: "hardcover", collection_id: "987", collection_title: "Series Name")

        assert_equal 1, items.size
        assert_equal "hardcover:111", items.first.work_id
        assert_equal "book", items.first.metadata_attrs[:content_kind]
        assert_equal "987", items.first.metadata_attrs[:collection_id]
      end
    end
  end

  test "validate! rejects unsupported and unconfigured collection sources" do
    assert_raises(MetadataCollectionService::Error) { MetadataCollectionService.validate!(source: "", collection_id: "1") }
    assert_raises(MetadataCollectionService::Error) { MetadataCollectionService.validate!(source: "comic_vine", collection_id: "") }

    error = assert_raises(MetadataCollectionService::Error) do
      MetadataCollectionService.validate!(source: "google_books", collection_id: "shelf-1")
    end
    assert_includes error.message, "not supported"

    ComicVineClient.stub(:configured?, false) do
      assert_raises(MetadataCollectionService::Error) { MetadataCollectionService.validate!(source: "comic_vine", collection_id: "4050-99") }
    end

    ComicVineClient.stub(:configured?, true) do
      assert_nothing_raised { MetadataCollectionService.validate!(source: "comic_vine", collection_id: "4050-99") }
    end
  end
end
