# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_account_test_helper"

class Kobo::ConnectionManagerTest < ActiveSupport::TestCase
  include KoboAccountTestHelper
  include ActiveJob::TestHelper

  test "starting a connection creates a private virtual device and records a real activation" do
    stub_kobo_activation
    account = Kobo::ConnectionManager.start(user: users(:one), name: "My books")
    assert_equal users(:one), account.user
    assert account.pending?
    assert_match(/\A[a-f0-9]{64}\z/, account.device_id)
    assert_match(/\A[a-f0-9]{32}\z/, account.serial_number)
    assert_equal "123456", account.activation_code
    assert_equal POLL_PATH, account.activation_poll_url
    assert_nil account.access_token
  end

  test "provider start failure is retained as a safe error and attempts are bounded per user" do
    stub_request(:get, %r{\A#{Regexp.escape(AUTH)}/ActivateOnWeb\?}).to_timeout
    3.times do
      account = Kobo::ConnectionManager.start(user: users(:one), name: "Attempt")
      assert_equal "failed", account.status
      assert_equal "provider_unavailable", account.last_error
    end
    assert_raises(Kobo::ConnectionManager::LimitReached) { Kobo::ConnectionManager.start(user: users(:one), name: "Fourth") }
    stub_kobo_activation
    assert Kobo::ConnectionManager.start(user: users(:two), name: "Other person").pending?
  end

  test "polling waits for the interval and claims it before contacting Kobo" do
    account = create_kobo_account(next_poll_at: 5.seconds.from_now)
    assert_equal :pending, Kobo::ConnectionManager.poll(account)
    assert_not_requested :post, AUTH + POLL_PATH
    travel 6.seconds do
      stub = stub_kobo_approval(status: "Pending")
      assert_equal :pending, Kobo::ConnectionManager.poll(account)
      assert_equal :pending, Kobo::ConnectionManager.poll(account.reload)
      assert_requested stub, times: 1
    end
  end

  test "approval stores real credentials clears the code and queues a private catalogue refresh" do
    account = create_kobo_account
    stub_kobo_approval
    stub_kobo_tokens
    assert_enqueued_with(job: KoboCatalogSyncJob) do
      assert_equal :approved, Kobo::ConnectionManager.poll(account)
    end
    saved = account.reload
    assert saved.connected?
    assert_nil saved.activation_code
    assert_nil saved.activation_poll_url
    assert_equal "synthetic-user-key", saved.kobo_user_key
    assert_equal "synthetic-access", saved.access_token
    assert_equal "queued", saved.sync_status
    assert_equal :approved, Kobo::ConnectionManager.poll(saved)
    assert_requested :post, STORE + "/v1/auth/device", times: 1
  end

  test "expired codes are cleared and never exchanged for credentials" do
    account = create_kobo_account(activation_expires_at: 1.second.ago)
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_equal "expired", account.reload.status
    assert_nil account.activation_code
    assert_nil account.activation_poll_url
    assert_not_requested :post, AUTH + POLL_PATH
    assert_not_requested :post, STORE + "/v1/auth/device"
  end

  test "Kobo errors never fall back to fake credentials and transient failures back off" do
    account = create_kobo_account
    stub_request(:post, AUTH + POLL_PATH).to_return(status: 503, body: "synthetic-private-error")
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_nil account.reload.access_token
    assert_equal "pending", account.status
    assert account.next_poll_at > 20.seconds.from_now
    assert_equal "provider_unavailable", account.last_error
    travel 31.seconds do
      stub_kobo_approval
      stub_request(:post, STORE + "/v1/auth/device").to_return(status: 401)
      assert_equal :failed, Kobo::ConnectionManager.poll(account.reload)
      assert_nil account.reload.access_token
      assert_nil account.activation_code
    end
  end

  test "a disconnect during device authentication cannot resurrect credentials" do
    account = create_kobo_account
    stub_kobo_approval
    stub_request(:post, STORE + "/v1/auth/device").to_return do
      KoboAccount.find(account.id).destroy!
      { body: kobo_tokens }
    end
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_not KoboAccount.exists?(account.id)
    assert_no_enqueued_jobs only: KoboCatalogSyncJob
  end

  test "a disconnect during a failed activation does not write or fail with a stale record" do
    account = create_kobo_account
    stub_request(:post, AUTH + POLL_PATH).to_return do
      KoboAccount.find(account.id).destroy!
      { status: 503 }
    end
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_not KoboAccount.exists?(account.id)
  end

  test "soft deleted users cannot poll or request a catalogue" do
    account = connect_kobo_account
    account.user.update!(deleted_at: Time.current)
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_not Kobo::ConnectionManager.request_catalogue(account)
    assert_no_enqueued_jobs only: KoboCatalogSyncJob
  end

  test "a queue failure leaves the connection usable and a refresh can be retried" do
    account = connect_kobo_account
    KoboCatalogSyncJob.stub(:perform_later, false) do
      assert_not Kobo::ConnectionManager.request_catalogue(account)
    end
    assert account.reload.connected?
    assert_equal "idle", account.sync_status
    assert_equal "queue_unavailable", account.last_error
    assert_enqueued_with(job: KoboCatalogSyncJob) { assert Kobo::ConnectionManager.request_catalogue(account) }
    assert_not Kobo::ConnectionManager.request_catalogue(account.reload)
  end

  test "invalid UTF-8 in a successful token response produces a recoverable protocol error" do
    account = create_kobo_account
    stub_kobo_approval
    body = '{"TokenType":"Bearer","AccessToken":"'.b + "\xff".b + '","RefreshToken":"synthetic"}'
    stub_request(:post, STORE + "/v1/auth/device").to_return(body: body)
    assert_equal :failed, Kobo::ConnectionManager.poll(account)
    assert_equal "protocol_changed", account.reload.last_error
    assert_nil account.access_token
  end
end
