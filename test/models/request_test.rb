# frozen_string_literal: true

require "test_helper"

class RequestTest < ActiveSupport::TestCase
  test "validates request scope" do
    request = Request.new(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending,
      request_scope: "invalid"
    )

    assert_not request.valid?
    assert_includes request.errors[:request_scope], "is not included in the list"
  end
end
