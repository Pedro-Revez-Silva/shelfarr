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

  def tag_names(result)
    result.items.filter_map { |item| item.except("NewEntitlement").transform_values { |value| value.dig("Tag", "Name") }.presence }
  end

  def add_deliveries(count)
    publication = KoboPublication.new(@book).snapshot
    count.times do
      @device.with_lock do
        @device.increment!(:sync_revision)
        @device.kobo_deliveries.create!(entitlement_id: SecureRandom.uuid, revision_id: SecureRandom.uuid, sync_revision: @device.sync_revision, publication: publication)
      end
    end
  end

  def change_tag(id, **attributes)
    @device.change_tags! do |tags, revision|
      tags.find_or_initialize_by(tag_id: id).tap { |tag| tag.update!(name: id, **attributes, sync_revision: revision) }
    end
  end

  test "collections share the bounded pages and every announcement is a replayable new collection" do
    change_tag("first")
    add_deliveries(99)
    change_tag("last")
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    first = sync.call(nil)
    assert first.more
    assert_equal [ [ "NewEntitlement", 99 ], [ "NewTag", 1 ] ], first.items.map { |item| item.keys.sole }.tally.to_a
    assert_equal [ { "NewTag" => "first" } ], tag_names(first)
    second = sync.call(first.token)
    assert_not second.more
    assert_equal [ { "NewTag" => "last" } ], tag_names(second)

    change_tag("first", name: "Renamed")
    third = sync.call(second.token)
    assert_equal [ { "NewTag" => "Renamed" } ], tag_names(third)
    assert_empty sync.call(third.token).items
  end

  test "a collection edited past a page boundary is still announced as new in a full replay" do
    change_tag("early")
    add_deliveries(100)
    change_tag("early", name: "Edited")
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    first = sync.call(nil)
    assert first.more
    assert_empty tag_names(first)
    assert_equal [ { "NewTag" => "Edited" } ], tag_names(sync.call(first.token))
  end

  test "a collection edited between pages of a snapshot is announced as new on the next sync" do
    add_deliveries(100)
    change_tag("late")
    sync = KoboSync.new(@device, endpoint: @device.endpoint(@token))
    first = sync.call(nil)
    change_tag("late", name: "Edited")
    second = sync.call(first.token)
    assert_empty tag_names(second)
    assert_equal [ { "NewTag" => "Edited" } ], tag_names(sync.call(second.token))
  end
end
