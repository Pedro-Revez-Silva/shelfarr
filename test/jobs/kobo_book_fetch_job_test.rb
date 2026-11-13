# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_household_test_helper"

class KoboBookFetchJobTest < ActiveJob::TestCase
  include KoboHouseholdTestHelper

  setup { setup_kobo_household }
  teardown { teardown_kobo_household }

  test "runs only the attempt it was queued for and carries no credentials" do
    stub_book_metadata
    stub_book_download
    row = Kobo::BookCache.request!(@shared_book, @owner)
    job = enqueued_jobs.find { |entry| entry["job_class"] == "KoboBookFetchJob" }
    assert_equal [ row.id, row.request_id ], job.fetch("arguments")
    assert_not_includes job.fetch("arguments").to_json, "synthetic-access"
    KoboBookFetchJob.perform_now(row.id, "another-request")
    assert_equal "fetching", row.reload.status
    assert_not_requested :get, KoboHouseholdTestHelper::DOWNLOAD_URL
    KoboBookFetchJob.perform_now(row.id, row.request_id)
    assert_equal "ready", row.reload.status
    KoboBookFetchJob.perform_now(row.id, row.request_id)
    assert_requested :get, KoboHouseholdTestHelper::DOWNLOAD_URL, times: 1
    KoboBookFetchJob.perform_now(0, row.request_id)
  end

  test "an unavailable queue records a retryable failure" do
    KoboBookFetchJob.stub(:perform_later, false) do
      row = Kobo::BookCache.request!(@shared_book, @owner)
      assert_equal [ "failed", "queue_unavailable" ], [ row.reload.status, row.error ]
    end
  end
end
