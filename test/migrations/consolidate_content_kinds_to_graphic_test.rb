# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260710000000_consolidate_content_kinds_to_graphic")

class ConsolidateContentKindsToGraphicTest < ActiveSupport::TestCase
  test "consolidates legacy manga while preserving existing graphics and books" do
    legacy_comic = Book.create!(title: "Legacy Comic", book_type: :comicbook, content_kind: :graphic)
    legacy_manga = Book.create!(title: "Legacy Manga", book_type: :comicbook, content_kind: :book)
    regular_book = Book.create!(title: "Regular Book", book_type: :ebook, content_kind: :book)
    connection = ActiveRecord::Base.connection
    connection.execute("UPDATE books SET content_kind = 2 WHERE id = #{connection.quote(legacy_manga.id)}")

    ConsolidateContentKindsToGraphic.new.up

    assert_equal "graphic", legacy_comic.reload.content_kind
    assert_equal "graphic", legacy_manga.reload.content_kind
    assert_equal "book", regular_book.reload.content_kind
    assert_includes Book.where(content_kind: :graphic), legacy_comic
    assert_includes Book.where(content_kind: :graphic), legacy_manga
  end

  test "is irreversible because the legacy distinction is intentionally discarded" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ConsolidateContentKindsToGraphic.new.down
    end
  end
end
