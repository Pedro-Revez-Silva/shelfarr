# frozen_string_literal: true

require "test_helper"

class OwnedLibraryConnectionTest < ActiveSupport::TestCase
  test "applies safe disabled Libation defaults" do
    connection = OwnedLibraryConnection.new

    assert connection.valid?, connection.errors.full_messages.join(", ")
    assert_equal "libation", connection.provider
    assert_equal "Audible Backup", connection.name
    assert_equal "http://shelfarr-libation:8080", connection.url
    assert_not connection.enabled?
    assert connection.allow_private_network?
  end

  test "normalizes URL and rejects embedded credentials" do
    connection = OwnedLibraryConnection.new(url: "https://companion.test/")
    assert connection.valid?
    assert_equal "https://companion.test", connection.url

    connection.url = "https://user:password@companion.test"
    assert_not connection.valid?
    assert_includes connection.errors[:url], "must be a valid http or https URL without embedded credentials"
  end

  test "allows a companion path prefix but rejects query and fragment components" do
    connection = OwnedLibraryConnection.new(
      url: "https://companion.test/reverse-proxy/libation",
      allow_private_network: false
    )
    assert connection.valid?, connection.errors.full_messages.join(", ")

    [
      "https://companion.test/reverse-proxy/libation?tenant=one",
      "https://companion.test/reverse-proxy/libation#settings",
      "https://companion.test/reverse-proxy/libation?",
      "https://companion.test/reverse-proxy/libation#"
    ].each do |url|
      connection.url = url
      assert_not connection.valid?, "#{url} would append API routes inside a query or fragment"
      assert_includes connection.errors[:url], "must not include a query string or fragment"
    end
  end

  test "requires HTTPS unless private network access is enabled" do
    connection = OwnedLibraryConnection.new(
      url: "http://public-companion.example",
      allow_private_network: false
    )

    assert_not connection.valid?
    assert_includes connection.errors[:url], "must use HTTPS unless private network access is enabled"

    connection.allow_private_network = true
    assert connection.valid?
  end

  test "encrypts manually configured bridge token" do
    connection = OwnedLibraryConnection.create!(bridge_token: "manual-secret")

    connection.reload
    assert_equal "manual-secret", connection.bridge_token
    assert_not_equal "manual-secret", connection.bridge_token_before_type_cast
  end

  test "requires a matching token before enabling a custom companion" do
    connection = OwnedLibraryConnection.new(
      url: "https://custom-companion.test",
      allow_private_network: false,
      enabled: true
    )

    assert_not connection.valid?
    assert_includes connection.errors[:bridge_token], "is required for an enabled custom companion URL"

    connection.bridge_token = "matching-secret"
    assert connection.valid?, connection.errors.full_messages.join(", ")
  end

  test "does not carry a custom token to a changed URL" do
    connection = OwnedLibraryConnection.create!(
      url: "https://first-companion.test",
      allow_private_network: false,
      enabled: true,
      bridge_token: "first-secret"
    )

    assert_not connection.update(url: "https://second-companion.test")
    assert_includes connection.errors[:bridge_token], "is required for an enabled custom companion URL"

    connection.reload
    assert_equal "https://first-companion.test", connection.url
    assert_equal "first-secret", connection.bridge_token

    assert connection.update(
      url: "https://second-companion.test",
      bridge_token: "second-secret"
    )
    assert_equal "second-secret", connection.reload.bridge_token
  end

  test "clears a manual token when switching to the managed companion URL" do
    connection = OwnedLibraryConnection.create!(
      url: "https://custom-companion.test",
      allow_private_network: false,
      enabled: true,
      bridge_token: "custom-secret"
    )

    with_env("SHELFARR_LIBATION_URL" => "http://shelfarr-libation:8080") do
      assert connection.update!(
        url: "http://shelfarr-libation:8080",
        allow_private_network: true
      )
    end

    assert_nil connection.reload.bridge_token
  end

  test "clears pending authentication and version state when the URL changes" do
    connection = OwnedLibraryConnection.create!(
      url: "https://first-companion.test",
      allow_private_network: false,
      enabled: true,
      bridge_token: "first-secret",
      auth_session_id: "session-1",
      auth_login_url: "https://www.amazon.com/ap/signin?example=1",
      auth_expires_at: 10.minutes.from_now,
      companion_version: "1.0.0",
      provider_version: "13.5.0"
    )

    connection.update!(
      url: "https://second-companion.test",
      bridge_token: "second-secret"
    )

    connection.reload
    assert_nil connection.auth_session_id
    assert_nil connection.auth_login_url
    assert_nil connection.auth_expires_at
    assert_nil connection.companion_version
    assert_nil connection.provider_version
  end

  test "encrypts temporary Audible authentication state" do
    connection = OwnedLibraryConnection.create!
    connection.update!(
      auth_session_id: "session-secret",
      auth_login_url: "https://www.amazon.com/ap/signin?secret=1",
      auth_expires_at: 10.minutes.from_now
    )

    connection.reload
    assert connection.auth_pending?
    assert_not_equal "session-secret", connection.auth_session_id_before_type_cast
    assert_not_equal "https://www.amazon.com/ap/signin?secret=1", connection.auth_login_url_before_type_cast

    connection.clear_auth_state!
    assert_not connection.reload.auth_pending?
  end

  test "allows only one connection per provider" do
    OwnedLibraryConnection.create!
    duplicate = OwnedLibraryConnection.new

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:provider], "has already been taken"
  end

  test "distinguishes queued and running sync activity" do
    connection = OwnedLibraryConnection.new(sync_status: "queued")

    assert connection.queued?
    assert connection.sync_active?
    assert_not connection.syncing?

    connection.sync_status = "syncing"
    assert connection.syncing?
    assert connection.sync_active?
  end

  test "stores a polling token alongside the companion job id without breaking legacy ids" do
    connection = OwnedLibraryConnection.new(sync_job_id: "legacy-job-id")

    assert_equal "legacy-job-id", connection.sync_job_id
    assert_nil connection.sync_poll_token

    connection.sync_job_id = connection.sync_job_state_value(
      job_id: "job:id/with symbols",
      poll_token: "poll-token"
    )

    assert_equal "job:id/with symbols", connection.sync_job_id
    assert_equal "poll-token", connection.sync_poll_token

    connection.sync_job_id = connection.sync_job_state_value(
      job_id: nil,
      poll_token: "startup-token"
    )

    assert_nil connection.sync_job_id
    assert_equal "startup-token", connection.sync_poll_token
  end

  test "applies disabled automation defaults without changing existing connection defaults" do
    connection = OwnedLibraryConnection.new

    assert_equal 1_440, connection.scheduled_sync_interval_minutes
    assert_not connection.scheduled_sync_enabled?
    assert_not connection.automatic_backup_enabled?
    assert_nil connection.next_scheduled_sync_at
    assert_nil connection.automatic_backup_enabled_at
    assert_nil connection.automatic_backup_user
    assert_not connection.backlog_backup_decided?
  end

  test "accepts only supported scheduled sync intervals" do
    connection = OwnedLibraryConnection.new(scheduled_sync_interval_minutes: 30)

    assert_not connection.valid?
    assert_includes connection.errors[:scheduled_sync_interval_minutes], "is not included in the list"

    OwnedLibraryConnection::SCHEDULED_SYNC_INTERVAL_MINUTES.each do |interval|
      connection.scheduled_sync_interval_minutes = interval
      assert connection.valid?, "expected #{interval} minutes to be valid"
    end

    assert_includes OwnedLibraryConnection::SCHEDULED_SYNC_INTERVAL_MINUTES, 60
  end

  test "maintains the next scheduled sync deadline when scheduling changes" do
    connection = OwnedLibraryConnection.create!

    travel_to Time.zone.local(2026, 7, 18, 10, 0, 0) do
      connection.update!(scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 360)
      assert_equal 6.hours.from_now, connection.next_scheduled_sync_at
      assert_equal 6.hours.from_now, connection.next_scheduled_sync_time

      connection.update!(scheduled_sync_interval_minutes: 720)
      assert_equal 12.hours.from_now, connection.next_scheduled_sync_at

      connection.update!(scheduled_sync_enabled: false)
      assert_nil connection.next_scheduled_sync_at
    end
  end

  test "sets a fresh automatic backup baseline and requires an active owner when enabling" do
    connection = OwnedLibraryConnection.create!

    assert_not connection.update(automatic_backup_enabled: true)
    assert_includes connection.errors[:automatic_backup_user], "must be an active administrator"

    assert_not connection.update(
      automatic_backup_enabled: true,
      automatic_backup_user: users(:one)
    )
    assert_includes connection.errors[:automatic_backup_user], "must be an active administrator"

    travel_to Time.zone.local(2026, 7, 18, 10, 0, 0) do
      connection.update!(automatic_backup_enabled: true, automatic_backup_user: users(:two))
      assert_equal Time.current, connection.automatic_backup_enabled_at
      assert connection.automatic_backup_ready?
      assert_not connection.automatic_backup_baseline_ready?

      connection.update!(last_synced_at: Time.current)
      assert connection.automatic_backup_baseline_ready?

      connection.update!(automatic_backup_enabled: false)
      assert_nil connection.automatic_backup_enabled_at

      travel 1.hour
      connection.update!(automatic_backup_enabled: true)
      assert_equal Time.current, connection.automatic_backup_enabled_at
    end
  end

  test "a nullified automatic backup owner pauses automation without blocking sync updates" do
    connection = OwnedLibraryConnection.create!(
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two)
    )
    connection.update_column(:automatic_backup_user_id, nil)
    connection.reload

    assert_not connection.automatic_backup_ready?
    assert connection.update(sync_status: "queued", sync_started_at: Time.current)
  end

  test "a demoted automatic backup owner pauses automation without blocking sync updates" do
    owner = users(:two)
    connection = OwnedLibraryConnection.create!(
      automatic_backup_enabled: true,
      automatic_backup_user: owner
    )
    owner.update!(role: :user)
    connection.reload

    assert_not connection.automatic_backup_ready?
    assert connection.update(sync_status: "queued", sync_started_at: Time.current)
  end

  test "cannot destroy a connection while sync or recoverable backup work is active" do
    connection = OwnedLibraryConnection.create!(
      sync_status: "syncing",
      sync_started_at: Time.current
    )

    assert_not connection.destroy
    assert connection.persisted?
    assert_match(/cannot be deleted safely/, connection.errors.full_messages.to_sentence)

    connection.update!(sync_status: "idle", sync_started_at: nil)
    item = connection.owned_library_items.create!(external_id: "B012345678", title: "Queued")
    item.owned_media_imports.create!(status: "pending", automatic: true)

    assert_not connection.destroy
    assert connection.persisted?
  end
end
