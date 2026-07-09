# frozen_string_literal: true

require "test_helper"

class RequestOptionPolicyTest < ActiveSupport::TestCase
  test "returns canonical book types for normalized content kinds" do
    assert_equal %w[audiobook ebook], RequestOptionPolicy.book_types_for("book")
    assert_equal [ "comicbook" ], RequestOptionPolicy.book_types_for("comic")
    assert_equal [ "comicbook" ], RequestOptionPolicy.book_types_for("manga")
    assert_equal RequestOptionPolicy.book_types_for("graphic"), RequestOptionPolicy.allowed_book_types("graphic")
  end
end
