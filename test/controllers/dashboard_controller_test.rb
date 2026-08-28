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

  test "recently added marks books already routed to the user's library" do
    routed_book = books(:audiobook_acquired)
    unrouted_book = Book.create!(
      title: "Dashboard Unrouted Audiobook",
      book_type: :audiobook,
      file_path: "/audiobooks/dashboard-unrouted"
    )
    @user.update!(preferred_output_path: "/tmp/user-library", library_routing_mode: "copy")
    UserBookPath.create!(user: @user, book: routed_book, file_path: "/tmp/user-library/routed.m4b")

    get root_path

    assert_response :success
    assert_select "a[href='#{library_path(routed_book)}'] span", text: "✓ Yours"
    assert_select "a[href='#{library_path(unrouted_book)}'] span", text: "✓ Yours", count: 0
  end

  test "recently added shows no routed badge when user has no routing configured" do
    routed_book = books(:audiobook_acquired)

    get root_path

    assert_response :success
    assert_select "a[href='#{library_path(routed_book)}'] span", text: "✓ Yours", count: 0
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
