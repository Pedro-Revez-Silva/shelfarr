# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_account_test_helper"

class KoboCatalogSyncJobTest < ActiveJob::TestCase
  include KoboAccountTestHelper

  setup { @account = connect_kobo_account(sync_status: "queued", sync_request_id: "request-1", sync_started_at: Time.current) }

  test "refresh imports metadata only and never makes a private purchase globally visible" do
    stub_kobo_catalogue(items: [ { "NewEntitlement" => { "BookSubscriptionEntitlement" => {} } }, kobo_book ])
    assert_no_difference [ "Book.count", "KoboDelivery.count" ] do
      assert_difference "KoboAccountBook.count", 1 do
        perform_enqueued_jobs { KoboCatalogSyncJob.perform_later(@account.id, "request-1") }
      end
    end
    assert_equal "A Purchased Book", @account.kobo_account_books.sole.title
    assert_equal "idle", @account.reload.sync_status
    assert_nil @account.last_error
    assert_not_nil @account.last_synced_at
  end

  test "a partial or failed refresh preserves the previous catalogue and successful sync time" do
    existing = @account.kobo_account_books.create!(entitlement_id: "existing", title: "Keep this")
    synced_at = 1.day.ago.change(usec: 0)
    @account.update!(last_synced_at: synced_at)
    stub_request(:get, STORE + "/v1/library/sync").with { |request| request.headers["X-Kobo-Synctoken"].nil? }
      .to_return(body: [ kobo_book ].to_json, headers: { "x-kobo-sync" => "continue", "x-kobo-synctoken" => "page-2" })
    stub_request(:get, STORE + "/v1/library/sync").with(headers: { "x-kobo-synctoken" => "page-2" }).to_return(status: 503)
    assert_no_difference "KoboAccountBook.count" do
      KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    end
    assert_equal existing.id, @account.kobo_account_books.sole.id
    assert_equal synced_at, @account.reload.last_synced_at
    assert_equal "provider_unavailable", @account.last_error
    assert @account.connected?
  end

  test "stale duplicate disconnected and soft deleted requests never fetch or publish" do
    KoboCatalogSyncJob.perform_now(@account.id, "old-request")
    @account.update!(sync_status: "syncing")
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    @account.update!(sync_status: "queued")
    @account.user.update!(deleted_at: Time.current)
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_not_requested :get, STORE + "/v1/library/sync"
    @account.destroy!
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_equal 0, KoboAccountBook.count
  end

  test "disconnect during a response cannot recreate books or credentials" do
    stub_request(:get, STORE + "/v1/library/sync").to_return do
      KoboAccount.find(@account.id).destroy!
      { body: [ kobo_book ].to_json }
    end
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_not KoboAccount.exists?(@account.id)
    assert_equal 0, KoboAccountBook.count
  end

  test "disconnect during a provider error is also safely discarded" do
    stub_request(:get, STORE + "/v1/library/sync").to_return do
      KoboAccount.find(@account.id).destroy!
      { status: 503 }
    end
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_not KoboAccount.exists?(@account.id)
  end

  test "expired refresh credentials preserve the catalogue and request reauthorization" do
    @account.kobo_account_books.create!(entitlement_id: "existing", title: "Keep this")
    stub_request(:get, STORE + "/v1/library/sync").to_return(status: 401)
    stub_request(:post, STORE + "/v1/auth/refresh").to_return(status: 401)
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_equal "reauthorization_required", @account.reload.status
    assert_equal "Keep this", @account.kobo_account_books.sole.title
    assert_equal "idle", @account.sync_status
  end

  test "invalid UTF-8 in catalogue JSON records a safe error and preserves the previous catalogue" do
    @account.kobo_account_books.create!(entitlement_id: "existing", title: "Keep this")
    body = [ kobo_book(title: "BAD_UTF8") ].to_json.b.sub("BAD_UTF8", "\xff".b)
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: body)
    KoboCatalogSyncJob.perform_now(@account.id, "request-1")
    assert_equal "protocol_changed", @account.reload.last_error
    assert_equal "idle", @account.sync_status
    assert_equal "Keep this", @account.kobo_account_books.sole.title
  end
end
