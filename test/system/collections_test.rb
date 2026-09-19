require "application_system_test_case"

class CollectionsTest < ApplicationSystemTestCase
  setup do
    @collection = BookCollection.create!(source: "hardcover", source_id: "800", title: "Seven Books")
    @memberships = 2.times.map do |index|
      work = BookWork.create!(source: "hardcover", source_id: "#{801 + index}", title: "Series Book #{index + 1}")
      @collection.collection_memberships.create!(book_work: work, position: (index + 1).to_s, sort_order: index)
    end
    sign_in_as(users(:one))
  end

  test "format checkboxes are independent and at least one is required" do
    visit collection_path(@collection)

    assert_checked_field "Ebooks"
    assert_unchecked_field "Audiobooks"
    assert_checked_field "Whole series"
    assert_selector "input[name='membership_ids[]']:disabled", count: 2
    uncheck "Ebooks"
    assert_button "Request missing books", disabled: true
    assert_text "Select ebooks, audiobooks, or both."
    check "Audiobooks"
    assert_button "Request missing books", disabled: false
    check "Ebooks"
    assert_checked_field "Audiobooks"
    assert_checked_field "Ebooks"
  end

  test "whole series can switch to an explicit selection including review entries" do
    @memberships.last.update!(ambiguous: true)
    visit collection_path(@collection)

    assert_text "Needs review"
    uncheck "Whole series"
    assert_selector "input[name='membership_ids[]']:not(:disabled)", count: 2
    assert_checked_field "membership_#{@memberships.first.id}"
    assert_unchecked_field "membership_#{@memberships.last.id}"
    uncheck "membership_#{@memberships.first.id}"
    assert_button "Request missing books", disabled: true
    assert_text "Select at least one book."
    check "membership_#{@memberships.last.id}"
    assert_button "Request missing books", disabled: false
    click_button "Request missing books"

    assert_text "1 request created."
    assert_equal 0, @memberships.first.book_work.books.joins(:requests).count
    assert_equal 1, @memberships.last.book_work.books.ebooks.joins(:requests).count
  end

  test "requesting both formats creates one request per work and format and is safe to repeat" do
    visit collection_path(@collection)
    check "Audiobooks"
    click_button "Request missing books"

    assert_current_path collection_path(@collection)
    assert_text "4 requests created."
    assert_selector "[data-format] dd", text: "Requested", count: 4
    check "Audiobooks"
    click_button "Request missing books"

    assert_text "0 requests created."
    assert_equal 4, Request.joins(:book).where(books: { book_work_id: @memberships.map(&:book_work_id) }).count
  end
end
