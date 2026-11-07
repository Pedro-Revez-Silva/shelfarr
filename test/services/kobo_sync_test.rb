# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboSyncTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup { prepare_kobo_book }
  teardown { FileUtils.remove_entry(@root) }

  test "snapshot pages are bounded, replayable and do not skip concurrent sends" do
    publication = KoboPublication.new(@book).snapshot
    101.times do |index|
      @device.kobo_deliveries.create!(entitlement_id: SecureRandom.uuid, revision_id: SecureRandom.uuid,
        first_revision: index + 1, sync_revision: index + 1, publication: publication)
    end
    @device.update!(sync_revision: 101)
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    first = sync.call(nil)
    assert_equal 100, first.items.size
    assert first.more
    assert_equal first.items, sync.call(nil).items

    sent = @device.send_book!(@book)
    second = sync.call(first.token)
    assert_equal 1, second.items.size
    assert_not second.more
    assert_equal "NewEntitlement", second.items.sole.keys.sole
    third = sync.call(second.token)
    assert_equal sent.entitlement_id, third.items.sole.fetch("NewEntitlement").fetch("BookEntitlement").fetch("Id")
    assert_empty sync.call(third.token).items
  end

  test "tampered and other-device cursors trigger safe full replay and rotation resets cursor" do
    @device.send_book!(@book)
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    cursor = sync.call(nil).token
    assert_empty sync.call(cursor).items
    assert_equal 1, sync.call("invalid").items.size
    assert_equal 1, sync.call("x" * 5000).items.size
    another, token = KoboDevice.issue(user: users(:one), name: "Another", base_url: @device.base_url)
    another.save!
    another.send_book!(@book)
    assert_equal 1, KoboSync.new(another, endpoint: another.endpoint(token)).call(cursor).items.size
    @device.rotate_token!
    assert_equal 1, sync.call(cursor).items.size
  end
end
