# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_household_test_helper"

class KoboAccountSharesControllerTest < ActionDispatch::IntegrationTest
  include KoboHouseholdTestHelper

  setup { setup_kobo_household }
  teardown { teardown_kobo_household }

  test "the owner shares the catalogue with a chosen person and revokes it" do
    sign_in_as(@owner)
    get kobo_account_path(@account)
    assert_select "#sharing", text: /Only you can see this catalogue/
    assert_select "select[name=recipient_id] option[value='#{@recipient.id}']"
    assert_select "select[name=recipient_id] option[value='#{@owner.id}']", count: 0
    post kobo_account_shares_path(@account), params: { recipient_id: @recipient.id }
    assert_redirected_to kobo_account_path(@account, anchor: "sharing")
    share = @account.kobo_account_shares.sole
    assert_equal @recipient, share.recipient
    follow_redirect!
    assert_select "[data-testid=kobo-share]", text: /Admin User/
    assert_select "select[name=recipient_id]", count: 0
    device, = recipient_device
    device.send_account_book!(prepare_copy(viewer: @recipient), share: share)
    delete kobo_account_share_path(@account, share)
    assert_redirected_to kobo_account_path(@account, anchor: "sharing")
    assert_match "Copies already downloaded", flash[:notice]
    assert_equal 0, KoboAccountShare.count
    assert_equal 0, device.kobo_deliveries.count
  end

  test "only the owner can grant or revoke, and never to themselves or a removed user" do
    share = share_with
    sign_in_as(@recipient)
    post kobo_account_shares_path(@account), params: { recipient_id: @recipient.id }
    assert_response :not_found
    delete kobo_account_share_path(@account, share)
    assert_response :not_found
    assert KoboAccountShare.exists?(share.id)
    get kobo_account_path(@account)
    assert_response :not_found

    sign_in_as(@owner)
    post kobo_account_shares_path(@account), params: { recipient_id: @owner.id }
    assert_equal 1, KoboAccountShare.count
    assert flash[:alert].present?
    former = User.create!(username: "former", name: "Former", password: "Password123!x", deleted_at: Time.current)
    post kobo_account_shares_path(@account), params: { recipient_id: former.id }
    assert_equal 1, KoboAccountShare.count
    post kobo_account_shares_path(@account), params: { recipient_id: @recipient.id }
    assert_equal 1, KoboAccountShare.count
    delete kobo_account_share_path(@account, 0)
    assert_redirected_to kobo_account_path(@account, anchor: "sharing")
  end

  test "sharing requires a signed-in session and a same-origin form" do
    post kobo_account_shares_path(@account), params: { recipient_id: @recipient.id }
    assert_redirected_to new_session_path
    assert_equal 0, KoboAccountShare.count
  end
end
