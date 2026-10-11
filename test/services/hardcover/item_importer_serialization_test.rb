# frozen_string_literal: true

require "test_helper"

# Uses real, separate database connections (no wrapping test transaction) to
# show that the importer's eligibility check and request creation form one
# write transaction: a pause issued while a request is being created waits
# for it, and the next item then sees the pause.
class Hardcover::ItemImporterSerializationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @settings_before = Setting.pluck(:id)
    @requests_before = Request.maximum(:id).to_i
    @books_before = Book.maximum(:id).to_i
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:immediate_search_enabled, false)
    @user = users(:one)
    @subscription = create_hardcover_subscription(@user, kind: "list", automatic: true)
  end

  teardown do
    Rails.configuration.x.hardcover_import_item_gap = 0
    HardcoverSubscriptionItem.delete_all
    HardcoverSubscription.delete_all
    HardcoverConnection.delete_all
    HardcoverRequestBudget.delete_all
    new_requests = Request.where("id > ?", @requests_before)
    Notification.where(notifiable: new_requests.to_a).delete_all
    ActivityLog.where(trackable: new_requests.to_a).delete_all
    new_requests.delete_all
    Book.where("id > ?", @books_before).delete_all
    Setting.where.not(id: @settings_before).delete_all
  end

  test "a pause issued during a request creation waits for it and stops the rest of the batch" do
    first = create_hardcover_item(@subscription, book_id: 9_800, state: "queued", wanted: false, book_types: [ "ebook" ])
    second = create_hardcover_item(@subscription, book_id: 9_801, state: "queued", wanted: false, book_types: [ "ebook" ])
    creating = Queue.new
    original = RequestCreationService.method(:call)
    timeline = Queue.new
    creator = lambda do |**args|
      result = original.call(**args)
      if args[:work_id] == first.work_id
        creating << true
        sleep 0.3
        timeline << [ :first_created, Process.clock_gettime(Process::CLOCK_MONOTONIC) ]
      end
      result
    end

    pauser = Thread.new do
      creating.pop
      ActiveRecord::Base.connection_pool.with_connection do
        HardcoverSubscription.find(@subscription.id).pause!("Paused by you.")
      end
      timeline << [ :paused, Process.clock_gettime(Process::CLOCK_MONOTONIC) ]
    end
    Rails.configuration.x.hardcover_import_item_gap = Hardcover::ItemImporter::ITEM_GAP
    result = RequestCreationService.stub(:call, creator) { Hardcover::ItemImporter.call }
    Timeout.timeout(10) { pauser.join }

    events = 2.times.map { timeline.pop }.to_h
    assert_operator events[:paused], :>, events[:first_created], "the pause waited for the request being created"
    assert_equal [ 1, 1 ], [ result.requested, result.cancelled ]
    assert_equal "requested", first.reload.state
    assert_equal [ "queued", nil ], [ second.reload.state, second.claim_token ]
    assert_equal 1, Request.where("id > ?", @requests_before).count
  end
end
