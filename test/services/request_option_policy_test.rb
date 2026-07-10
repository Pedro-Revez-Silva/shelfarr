# frozen_string_literal: true

require "test_helper"

class RequestOptionPolicyTest < ActiveSupport::TestCase
  test "returns canonical book types for normalized content kinds" do
    assert_equal %w[audiobook ebook], RequestOptionPolicy.book_types_for("book")
    assert_equal [ "comicbook" ], RequestOptionPolicy.book_types_for("comic")
    assert_equal [ "comicbook" ], RequestOptionPolicy.book_types_for("manga")
    assert_equal RequestOptionPolicy.book_types_for("graphic"), RequestOptionPolicy.allowed_book_types("graphic")
  end

  test "validates requested formats and reports incompatible ones" do
    assert RequestOptionPolicy.permitted_book_types?(%w[audiobook ebook], "book")
    assert RequestOptionPolicy.permitted_book_types?([ "comicbook" ], "manga")
    assert_not RequestOptionPolicy.permitted_book_types?([ "ebook" ], "graphic")
    assert_equal [ "comicbook" ], RequestOptionPolicy.incompatible_book_types(%w[audiobook ebook comicbook], "book")
    assert_equal %w[audiobook ebook], RequestOptionPolicy.incompatible_book_types(%w[audiobook ebook comicbook], "graphic")
  end

  test "provides stable labels including a fallback for unknown formats" do
    assert_equal "Audiobook", RequestOptionPolicy.book_type_label("audiobook")
    assert_equal "Ebook", RequestOptionPolicy.book_type_label("ebook")
    assert_equal "Comics & Manga", RequestOptionPolicy.book_type_label("comicbook")
    assert_equal "Print edition", RequestOptionPolicy.book_type_label("print_edition")
    assert_equal "Comics & Manga", RequestOptionPolicy.content_kind_label("comic")
    assert_equal "book", RequestOptionPolicy.content_kind_label("book")
  end
end
