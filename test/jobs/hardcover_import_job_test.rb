# frozen_string_literal: true

require "test_helper"

class HardcoverImportJobTest < ActiveJob::TestCase
  test "continues in another batch while queued items remain" do
    SettingsService.set(:hardcover_enabled, true)
    subscription = create_hardcover_subscription(users(:one), book_types: [ "ebook" ])
    (Hardcover::ItemImporter::BATCH_SIZE + 2).times do |index|
      create_hardcover_item(subscription, book_id: 7_000 + index, state: "queued", wanted: true, book_types: [ "ebook" ])
    end

    assert_enqueued_with(job: HardcoverImportJob) { HardcoverImportJob.perform_now }
    assert_equal 2, subscription.items.queued.count
  end

  test "stops when nothing is left" do
    SettingsService.set(:hardcover_enabled, true)

    assert_no_enqueued_jobs(only: HardcoverImportJob) { HardcoverImportJob.perform_now }
  end

  # Runs the import job and every continuation it schedules, the way Solid
  # Queue would, and returns the delays it asked for.
  def run_import_chain
    clear_enqueued_jobs
    delays = []
    10.times do
      HardcoverImportJob.perform_now
      continuation = enqueued_jobs.select { |job| job[:job] == HardcoverImportJob }
      return delays if continuation.empty?

      delays << continuation.last[:at] - Time.current.to_f
      clear_enqueued_jobs
    end
    flunk "the import kept continuing"
  end

  test "one check's automatic requests stay within the limit across continuation batches and windows" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:hardcover_max_requests_per_run, 10)
    configure_hardcover_instance_token
    user = users(:one)
    subscription = create_hardcover_subscription(user, kind: "list", automatic: true, book_types: [ "ebook" ], baseline: 10.days.ago)
    rows = (1..50).map { |index| hardcover_list_book_row(hardcover_book(id: 20_000 + index), id: index, date_added: 1.hour.ago.iso8601) }
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => rows })

    assert_equal 50, Hardcover::SubscriptionSync.call(subscription).queued
    selected = create_hardcover_item(subscription, book_id: 30_000, state: "queued", wanted: true, book_types: [ "audiobook" ])
    other = create_hardcover_subscription(users(:two), kind: "list", automatic: true)
    others = 3.times.map { |index| create_hardcover_item(other, book_id: 31_000 + index, state: "queued", book_types: [ "ebook" ]) }
    automatic = subscription.items.where(wanted: false).order(:id).to_a

    delays = nil
    assert_difference -> { Request.where(user: user).count } => 11, -> { Request.where(user: users(:two)).count } => 3 do
      delays = run_import_chain
    end
    assert_equal 1, delays.size, "the batch after the first one continued"
    assert_in_delta HardcoverImportJob::CONTINUE_DELAY, delays.first, 1
    assert_equal "requested", selected.reload.state, "the user's own selection is not limited"
    assert others.all? { |item| item.reload.requested? }, "another user's queue is not held up"
    assert_equal automatic.first(10).map(&:id), automatic.select { |item| item.reload.requested? }.map(&:id),
      "the continuation batch did not get a fresh limit"

    # Each later window requests the next ten in order until all are done.
    (2..5).each do |window|
      travel((window - 1) * (6.hours + 1.minute)) do
        HardcoverSyncSchedulerJob.perform_now
        assert_difference -> { Request.where(user: user).count } => 10 do
          run_import_chain
        end
        assert_equal automatic.first(window * 10).map(&:id), automatic.select { |item| item.reload.requested? }.map(&:id)
      end
    end
    assert_equal 50, Request.where(user: user, created_via: "hardcover").joins(:book).where(books: { book_type: "ebook" }).count
  end

  test "an automatic book's formats are split across windows without being requested twice" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:hardcover_max_requests_per_run, 3)
    subscription = create_hardcover_subscription(users(:one), kind: "list", automatic: true, book_types: %w[ebook audiobook])
    items = 3.times.map { |index| create_hardcover_item(subscription, book_id: 32_000 + index, state: "queued", book_types: %w[ebook audiobook]) }

    created = []
    3.times do |window|
      travel window * (6.hours + 1.minute) do
        before = Request.count
        run_import_chain
        created << Request.count - before
      end
    end

    assert_equal [ 3, 3, 0 ], created
    assert items.all? { |item| item.reload.requested? }
    items.each do |item|
      assert_equal %w[audiobook ebook], Request.where(id: item.request_ids).map { |request| request.book.book_type }.sort
    end
  end
end
