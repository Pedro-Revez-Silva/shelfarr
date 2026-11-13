# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_household_test_helper"

class KoboAccountShareTest < ActiveSupport::TestCase
  include KoboHouseholdTestHelper

  setup { setup_kobo_household }
  teardown { teardown_kobo_household }

  test "accounts are private by default and shares go only to other active users" do
    assert_empty Kobo::HouseholdAccess.visible_books(@recipient)
    assert_equal [ @shared_book ], Kobo::HouseholdAccess.visible_books(@owner).to_a
    assert_not @account.kobo_account_shares.new(recipient: @owner).valid?
    assert_not @account.kobo_account_shares.new(recipient: nil).valid?
    deleted = User.create!(username: "former", name: "Former", password: "Password123!x", deleted_at: Time.current)
    assert_not @account.kobo_account_shares.new(recipient: deleted).valid?
    share_with
    assert_not @account.kobo_account_shares.new(recipient: @recipient).valid?
    assert_equal [ @shared_book ], Kobo::HouseholdAccess.visible_books(@recipient).to_a
  end

  test "a share applies only while both people remain active" do
    share = share_with
    assert @account.visible_to?(@recipient)
    assert_equal share, Kobo::HouseholdAccess.grant!(@recipient, @account).share
    assert Kobo::HouseholdAccess.grant!(@owner, @account).owner?
    @owner.update!(deleted_at: Time.current)
    assert_not @account.reload.visible_to?(@recipient)
    assert_empty Kobo::HouseholdAccess.visible_books(@recipient)
    assert_empty Kobo::HouseholdAccess.visible_books(@owner)
    assert_raises(Kobo::HouseholdAccess::Denied) { Kobo::HouseholdAccess.grant!(@recipient, @account) }
    @owner.update!(deleted_at: nil)
    @recipient.update!(deleted_at: Time.current)
    assert_not share.reload.effective?
    assert_empty KoboAccountShare.effective
    assert_empty Kobo::HouseholdAccess.visible_books(@recipient)
  end

  test "shares are limited per account and removed with either person" do
    users = Array.new(KoboAccountShare::MAX_PER_ACCOUNT) do |index|
      User.create!(username: "member#{index}", name: "Member #{index}", password: "Password123!x")
    end
    users.each { |user| share_with(user) }
    assert_not @account.kobo_account_shares.new(recipient: @recipient).valid?
    users.first.destroy!
    assert_equal KoboAccountShare::MAX_PER_ACCOUNT - 1, @account.kobo_account_shares.count
    @owner.destroy!
    assert_equal 0, KoboAccountShare.count
  end

  test "eligibility explains every non-sendable title and the sendable scope agrees" do
    cases = {
      { archived: true } => :archived, { media_type: "audiobook" } => :audiobook,
      { ownership_type: "subscription" } => :subscription, { ownership_type: "preview" } => :preview,
      { ownership_type: "unknown" } => :ownership_unknown, { rights_checked_at: nil } => :unchecked,
      { rights: "protected" } => :protected, { rights: "unsupported" } => :unsupported_format,
      { rights: "none_offered" } => :no_download, {} => :eligible
    }
    cases.each do |attributes, expected|
      @shared_book.update!({ archived: false, media_type: "ebook", ownership_type: "purchased", rights: "drm_free",
        rights_checked_at: Time.current }.merge(attributes))
      assert_equal expected, @shared_book.delivery_eligibility
      assert_equal expected == :eligible, KoboAccountBook.sendable.exists?(@shared_book.id), expected
    end
  end
end
