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

  test "system card only counts degraded and down services as issues, not not_configured" do
    SystemHealth.delete_all

    SystemHealth.create!(service: "indexer", status: :healthy)
    SystemHealth.create!(service: "download_client", status: :not_configured)
    SystemHealth.create!(service: "download_paths", status: :degraded)
    SystemHealth.create!(service: "output_paths", status: :down)
    SystemHealth.create!(service: "audiobookshelf", status: :not_configured)

    get root_path

    assert_response :success
    assert_select "[data-system-health-card] .text-2xl", text: "2 Issues"
    assert_select "a[data-system-health-card]", count: 0
  end

  test "system card is clickable for admins" do
    admin = users(:two)
    sign_in_as(admin)

    get root_path

    assert_response :success
    assert_select "a[data-system-health-card][href='#{admin_root_path(anchor: "system-health")}']", text: /System/
  end

  test "system card shows Healthy when no degraded or down services" do
    SystemHealth.delete_all

    SystemHealth.create!(service: "indexer", status: :healthy)
    SystemHealth.create!(service: "download_client", status: :not_configured)

    get root_path

    assert_response :success
    assert_select "[data-system-health-card] .text-2xl", text: "Healthy"
  end
end
