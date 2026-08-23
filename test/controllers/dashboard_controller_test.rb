# frozen_string_literal: true

require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "labels recent comic library items and requests as Comics and Manga" do
    book = Book.create!(
      title: "Dashboard Comic Label",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-dashboard-label",
      file_path: "/comics/dashboard-label.cbz"
    )
    request = Request.create!(book: book, user: @user, status: :pending)

    get root_path

    assert_response :success
    assert_select "a[href='#{library_path(book)}'] span[class*='bg-emerald-500/90']",
      text: "Comics & Manga"
    assert_select "a[href='#{request_path(request)}'] span[class*='bg-emerald-500/90']",
      text: "Comics & Manga"
  end
end
