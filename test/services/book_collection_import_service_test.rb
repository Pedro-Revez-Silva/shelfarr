require "test_helper"

class BookCollectionImportServiceTest < ActiveSupport::TestCase
  test "saves works rather than editions and shares them across series and formats" do
    ebook = Book.create!(hardcover_id: "9101", title: "Old edition", book_type: :ebook,
      isbn: "1111111111", year: 1997, file_path: "/ebooks/old.epub")
    audio = Book.create!(hardcover_id: "9101", title: "New recording", book_type: :audiobook,
      isbn: "2222222222", year: 2026)
    result = import([ entry("9101", position: "1"), entry("9101", position: "1") ])

    assert_equal 1, result.collection_memberships.count
    work = result.book_works.sole
    assert_equal work, ebook.reload.book_work
    assert_equal work, audio.reload.book_work
    assert_equal "/ebooks/old.epub", ebook.file_path
    assert_equal "1111111111", ebook.isbn
    assert_equal 1997, ebook.year

    other = import([ entry("9101", position: "3") ], source_id: "502")
    assert_equal work, other.book_works.sole
    assert_equal "3", other.collection_memberships.sole.position
    assert_equal "1", result.collection_memberships.sole.position
  end

  test "flags distinct works sharing a numbered position without collapsing unknown positions" do
    result = import([ entry("9101", position: "1"), entry("9102", position: "1.0"),
      entry("9103", position: nil), entry("9104", position: nil) ])

    assert_equal 4, result.book_works.count
    assert_equal [ true, true, false, false ], result.collection_memberships.map(&:ambiguous?)
  end

  test "refresh replaces membership only after successful complete fetch and preserves copies" do
    result = import([ entry("9101", position: "1"), entry("9102", position: "2") ])
    work = result.book_works.find_by!(source_id: "9101")
    ebook = Book.create!(hardcover_id: "9101", title: "Saved copy", book_type: :ebook, file_path: "/ebooks/copy.epub")

    HardcoverClient.stub(:series_books, ->(*) { raise HardcoverClient::RateLimitError, "wait" }) do
      assert_raises(BookCollectionImportService::Error) { BookCollectionImportService.call(source_id: "501") }
    end
    assert_equal 2, result.collection_memberships.count

    import([ entry("9102", position: "2") ])
    assert_equal [ "9102" ], result.reload.book_works.pluck(:source_id)
    assert_equal work, ebook.reload.book_work
    assert_equal "/ebooks/copy.epub", ebook.file_path
  end

  test "does not guess identity from matching title author ISBN or year" do
    legacy = Book.create!(title: "Book 9101", author: "Author", book_type: :ebook, google_books_id: "volume-1")
    result = import([ entry("9101", position: "1"), entry("9102", position: "2") ])

    assert_equal 2, result.book_works.count
    assert_nil legacy.reload.book_work
  end

  test "rejects invalid IDs empty and malformed snapshots without saving collections" do
    [ "", "https://example.com/series/1", "-1", "1garbage", "2147483648" ].each do |id|
      assert_no_difference "BookCollection.count" do
        assert_raises(BookCollectionImportService::Error) { BookCollectionImportService.call(source_id: id) }
      end
    end

    [ [], [ entry("bad", position: "1") ] ].each do |entries|
      assert_no_difference "BookCollection.count" do
        assert_raises(BookCollectionImportService::Error) { import(entries) }
      end
    end
  end

  private

  def import(entries, source_id: "501")
    HardcoverClient.stub(:series_books, entries) { BookCollectionImportService.call(source_id: source_id) }
  end

  def entry(id, position:)
    HardcoverClient::SearchResult.new(id: id, title: "Book #{id}", author: "Author", description: "Description",
      release_year: 1997, cover_url: nil, has_audiobook: false, has_ebook: false,
      series_name: "Example Series", series_position: position)
  end
end
