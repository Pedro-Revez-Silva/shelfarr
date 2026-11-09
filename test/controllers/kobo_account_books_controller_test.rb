# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_household_test_helper"

class KoboAccountBooksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include KoboHouseholdTestHelper

  setup do
    setup_kobo_household
    @stranger = User.create!(username: "neighbour", name: "Neighbour", password: "Password123!x")
  end

  teardown { teardown_kobo_household }

  def member_paths
    [ [ :get, kobo_account_book_path(@shared_book) ], [ :post, prepare_kobo_account_book_path(@shared_book) ],
      [ :post, deliver_kobo_account_book_path(@shared_book) ], [ :post, status_kobo_account_book_path(@shared_book) ],
      [ :get, cover_kobo_account_book_path(@shared_book) ] ]
  end

  test "people without a share, including after revocation, cannot see any book boundary" do
    share = share_with
    prepare_copy
    sign_in_as(@stranger)
    assert_no_enqueued_jobs(only: KoboBookFetchJob) do
      member_paths.each do |verb, path|
        send(verb, path)
        assert_response :not_found, path
      end
    end
    get kobo_shared_library_path(@account)
    assert_response :not_found
    sign_in_as(@recipient)
    get kobo_account_book_path(@shared_book)
    assert_response :success
    share.destroy!
    assert_no_enqueued_jobs(only: KoboBookFetchJob) do
      member_paths.each do |verb, path|
        send(verb, path)
        assert_response :not_found, path
      end
    end
  end

  test "a recipient browses the shared catalogue, prepares a copy and sends it to their own reader" do
    share_with
    @account.kobo_account_books.create!(entitlement_id: "locked", title: "A Protected Purchase", ownership_type: "purchased",
      rights: "protected", rights_checked_at: Time.current)
    sign_in_as(@recipient)
    get profile_path
    assert_select "a[href='#{kobo_shared_libraries_path}']", text: "Shared Kobo books"
    get kobo_shared_libraries_path
    assert_select "a[href='#{kobo_shared_library_path(@account)}']", text: "Family purchases"
    assert_select "body", text: /Shared by User One · 1 book can be sent/
    get kobo_shared_library_path(@account, filter: "sendable")
    assert_select "[data-testid=kobo-catalogue-entry]", count: 1
    assert_select "[data-testid=kobo-catalogue-entry]", text: /A Shared Purchase/
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-eligibility]", text: "DRM-free EPUB · can be sent"
    assert_select "[data-testid=kobo-no-reader]"
    assert_not_includes response.body, "reader@example.test"
    assert_not_includes response.body, "synthetic-access"
    assert_includes response.headers["Cache-Control"], "no-store"

    assert_enqueued_with(job: KoboBookFetchJob) { post prepare_kobo_account_book_path(@shared_book) }
    follow_redirect!
    assert_select "[data-controller=kobo-account]", text: /Preparing a private copy/
    post status_kobo_account_book_path(@shared_book), as: :json
    assert_equal "pending", response.parsed_body.fetch("status")
    stub_book_metadata
    stub_book_download
    perform_enqueued_jobs only: KoboBookFetchJob
    post status_kobo_account_book_path(@shared_book), as: :json
    assert_equal kobo_account_book_path(@shared_book), response.parsed_body.fetch("redirect_url")

    device, = recipient_device
    other_device, = recipient_device(@owner)
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-copy-status]", text: /Ready · EPUB3 3.0/
    assert_select "button", text: "Send to #{device.name}"
    get cover_kobo_account_book_path(@shared_book)
    assert_equal "image/png", response.media_type
    post deliver_kobo_account_book_path(@shared_book), params: { device_id: other_device.id }
    assert_response :not_found
    assert_equal 0, other_device.kobo_deliveries.count
    post deliver_kobo_account_book_path(@shared_book), params: { device_id: device.id }
    assert_redirected_to kobo_account_book_path(@shared_book)
    delivery = device.kobo_deliveries.sole
    assert_equal @account.kobo_account_shares.sole, delivery.kobo_account_share
    assert_nil delivery.book
    get kobo_device_path(device)
    assert_select "[data-testid=kobo-delivery]", text: /Shared Kobo book · Queued/
  end

  test "ineligible, stale and failed states explain themselves without send buttons" do
    sign_in_as(@owner)
    @shared_book.update!(rights: "protected")
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-eligibility]", text: /Protected by DRM/
    assert_select "form[action*='/kobo_books/']", count: 0
    post prepare_kobo_account_book_path(@shared_book)
    assert_match "no longer lists a DRM-free EPUB", flash[:alert]

    @shared_book.update!(rights: "drm_free")
    stub_book_metadata
    stub_book_download(synthetic_epub.byteslice(0, 50), length: 50)
    @shared_book.update!(download_size: synthetic_epub.bytesize)
    row = Kobo::BookCache.request!(@shared_book, @owner)
    Kobo::BookCache.new(row).call
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-copy-error]", text: /download was incomplete/
    assert_select "button", text: "Try again"

    prepare_copy
    @shared_book.update!(revision_id: "edition-2")
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-copy-stale]"
    assert_select "[data-testid=kobo-copy-error]", count: 0
    @shared_book.update!(rights_checked_at: nil)
    get kobo_account_book_path(@shared_book)
    assert_select "[data-testid=kobo-eligibility]", text: /refresh needed/
  end

  test "the owner's own catalogue links to the book page and owner devices are offered" do
    prepare_copy
    device, = recipient_device(@owner)
    sign_in_as(@owner)
    get kobo_account_path(@account)
    assert_select "a[href='#{kobo_account_book_path(@shared_book)}']", text: "A Shared Purchase"
    get kobo_shared_library_path(@account)
    assert_redirected_to kobo_account_path(@account)
    post deliver_kobo_account_book_path(@shared_book), params: { device_id: device.id }
    assert_nil device.kobo_deliveries.sole.kobo_account_share
  end
end
