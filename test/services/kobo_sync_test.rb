# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboSyncTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup { prepare_kobo_book }
  teardown { FileUtils.remove_entry(@root) }

  test "snapshot pages are bounded, replayable and do not skip concurrent sends" do
    publication = KoboPublication.new(@book).snapshot
    102.times do |index|
      @device.kobo_deliveries.create!(entitlement_id: SecureRandom.uuid, revision_id: SecureRandom.uuid,
        book: index == 100 ? @book : nil, sync_revision: index + 1, publication: publication)
    end
    @device.update!(sync_revision: 102)
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

  test "collections share the bounded pages and are announced once as new, then as changed" do
    publication = KoboPublication.new(@book).snapshot
    99.times do |index|
      @device.kobo_deliveries.create!(entitlement_id: SecureRandom.uuid, revision_id: SecureRandom.uuid, sync_revision: index + 2, publication: publication)
    end
    @device.kobo_tags.create!(tag_id: "first", name: "First", created_revision: 1, sync_revision: 1)
    @device.kobo_tags.create!(tag_id: "last", name: "Last", created_revision: 101, sync_revision: 101)
    @device.update!(sync_revision: 101)
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    first = sync.call(nil)
    assert first.more
    assert_equal [ [ "NewEntitlement", 99 ], [ "NewTag", 1 ] ], first.items.map { |item| item.keys.sole }.tally.to_a
    assert_equal "First", first.items.last.dig("NewTag", "Tag", "Name")
    second = sync.call(first.token)
    assert_not second.more
    assert_equal [ { "NewTag" => "Last" } ], second.items.map { |item| item.transform_values { |value| value.dig("Tag", "Name") } }

    @device.change_tags! { |tags, revision| tags.find_by!(tag_id: "first").update!(name: "Renamed", sync_revision: revision) }
    third = sync.call(second.token)
    assert_equal [ { "ChangedTag" => "Renamed" } ], third.items.map { |item| item.transform_values { |value| value.dig("Tag", "Name") } }
    assert_empty sync.call(third.token).items
  end
end
