# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_account_test_helper"

class KoboAccountTest < ActiveSupport::TestCase
  include KoboAccountTestHelper

  test "all credentials and activation data are encrypted at rest and hidden from inspect" do
    account = connect_kobo_account
    persisted = KoboAccount.find(account.id)
    KoboAccount::PRIVATE_ATTRIBUTES.each do |attribute|
      value = account.public_send(attribute)
      assert_equal value, persisted.public_send(attribute)
      assert_not_equal value, persisted.read_attribute_before_type_cast(attribute)
      assert_includes persisted.read_attribute_before_type_cast(attribute), '"p"'
      assert_not_includes persisted.inspect, value
    end
  end

  test "catalogue uniqueness is scoped to its connection and disconnect keeps the shared library" do
    account = connect_kobo_account
    other = connect_kobo_account(user: users(:two))
    [ account, other ].each { |owner| owner.kobo_account_books.create!(entitlement_id: "same-book", title: "Title") }
    assert_not account.kobo_account_books.new(entitlement_id: "same-book", title: "Duplicate").valid?
    assert_no_difference "Book.count" do
      assert_difference "KoboAccountBook.count", -1 do
        account.destroy!
      end
    end
    assert_equal 1, other.kobo_account_books.count
  end

  test "soft deleted users cannot use a connection and an expired operation can be retried" do
    account = connect_kobo_account(sync_status: "syncing", sync_started_at: Time.current)
    assert account.usable?
    assert account.sync_active?
    travel 6.minutes do
      assert_not account.sync_active?
    end
    account.user.update!(deleted_at: Time.current)
    assert_not account.usable?
  end
end
