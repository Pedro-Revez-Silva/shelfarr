# frozen_string_literal: true

require "test_helper"

class DetectedImportTest < ActiveSupport::TestCase
  test "requires a source path and a valid status" do
    detection = DetectedImport.new(source_path: "", status: "detected")
    assert_not detection.valid?
    assert_includes detection.errors[:source_path], "can't be blank"

    detection.source_path = "/data/torrents/shelfarr/book.epub"
    detection.status = "bogus"
    assert_not detection.valid?
    assert_includes detection.errors[:status], "is not included in the list"
  end

  test "rejects an unknown book_type but allows nil" do
    detection = DetectedImport.new(source_path: "/x", status: "detected", book_type: "movie")
    assert_not detection.valid?

    detection.book_type = nil
    assert detection.valid?
  end

  test "actionable? is true only for detected and failed" do
    assert DetectedImport.new(status: "detected").actionable?
    assert DetectedImport.new(status: "failed").actionable?
    assert_not DetectedImport.new(status: "importing").actionable?
    assert_not DetectedImport.new(status: "imported").actionable?
    assert_not DetectedImport.new(status: "dismissed").actionable?
  end

  test "a stale importing row becomes actionable again for recovery" do
    detection = DetectedImport.create!(source_path: "/x", status: "importing")
    detection.update_column(:updated_at, 2.hours.ago)

    assert detection.stuck_importing?
    assert detection.actionable?
  end

  test "a freshly importing row is not treated as stuck" do
    detection = DetectedImport.create!(source_path: "/y", status: "importing")

    assert_not detection.stuck_importing?
    assert_not detection.actionable?
  end

  test "default_selection prefers an existing library suggestion" do
    book = Book.create!(title: "Elantris", book_type: :ebook)
    detection = DetectedImport.new(
      source_path: "/x", status: "detected", suggested_book: book,
      candidate_books: [ { "kind" => "online", "work_id" => "hardcover:1", "score" => 90 } ]
    )
    assert_equal "book:#{book.id}", detection.default_selection
  end

  test "default_selection falls back to the highest-scoring alternate, not new" do
    detection = DetectedImport.new(source_path: "/x", status: "detected", candidate_books: [
      { "kind" => "online", "work_id" => "hardcover:1", "score" => 40 },
      { "kind" => "online", "work_id" => "hardcover:2", "score" => 88 }
    ])
    assert_equal "hardcover:2", detection.best_candidate["work_id"]
    assert_equal "work:hardcover:2", detection.default_selection
  end

  test "default_selection is new only when nothing was matched" do
    detection = DetectedImport.new(source_path: "/x", status: "detected")
    assert_nil detection.best_candidate
    assert_equal "new", detection.default_selection
  end

  test "candidate_books always reads back as an array" do
    detection = DetectedImport.new(source_path: "/x", status: "detected")
    assert_equal [], detection.candidate_books

    detection.candidate_books = [ { "kind" => "library", "book_id" => 1 } ]
    assert_equal 1, detection.candidate_books.size
  end

  test "display_title falls back to the source basename" do
    detection = DetectedImport.new(source_path: "/data/torrents/shelfarr/Some Book.epub")
    assert_equal "Some Book.epub", detection.display_title

    detection.parsed_title = "Some Book"
    assert_equal "Some Book", detection.display_title
  end

  test "pending_review excludes dismissed and imported" do
    detected = DetectedImport.create!(source_path: "/a", status: "detected")
    failed = DetectedImport.create!(source_path: "/b", status: "failed")
    DetectedImport.create!(source_path: "/c", status: "dismissed")
    DetectedImport.create!(source_path: "/d", status: "imported")

    ids = DetectedImport.pending_review.pluck(:id)
    assert_includes ids, detected.id
    assert_includes ids, failed.id
    assert_equal 2, ids.size
  end
end
