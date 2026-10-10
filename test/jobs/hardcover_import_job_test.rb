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
end
