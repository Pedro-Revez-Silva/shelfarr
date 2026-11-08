# frozen_string_literal: true

require "test_helper"

class KoboAccountBookTest < ActiveSupport::TestCase
  test "invalid catalogue types and missing titles are rejected" do
    book = KoboAccountBook.new(entitlement_id: "book", title: "", media_type: "html", ownership_type: "purchased")
    assert_not book.valid?
    assert_includes book.errors.attribute_names, :title
    assert_includes book.errors.attribute_names, :media_type
  end
end
