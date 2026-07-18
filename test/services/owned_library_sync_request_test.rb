# frozen_string_literal: true

require "test_helper"

class OwnedLibrarySyncRequestTest < ActiveJob::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(enabled: true)
  end

  test "manual requests durably claim and enqueue a sync" do
    result = nil

    assert_enqueued_with(job: OwnedLibrarySyncJob) do
      result = OwnedLibrarySyncRequest.call(connection: @connection, mode: :manual)
    end

    assert_equal :queued, result.status
    assert result.enqueued?
    assert result.job.successfully_enqueued?
    assert_equal @connection.id, result.job.arguments.first
    assert @connection.reload.queued?
    assert_equal result.poll_token, @connection.sync_poll_token
    assert_nil @connection.last_sync_error
  end

  test "scheduled requests honor their enabled flag and due time" do
    disabled = OwnedLibrarySyncRequest.call(connection: @connection, mode: :scheduled)
    assert_equal :scheduled_sync_disabled, disabled.status

    @connection.update!(scheduled_sync_enabled: true)
    not_due = OwnedLibrarySyncRequest.call(connection: @connection, mode: :scheduled)
    assert_equal :not_due, not_due.status
    assert_no_enqueued_jobs only: OwnedLibrarySyncJob
  end

  test "a successful scheduled enqueue stays due until the sync reaches a terminal state" do
    now = Time.zone.local(2026, 7, 18, 10, 0, 0)
    @connection.update!(
      scheduled_sync_enabled: true,
      scheduled_sync_interval_minutes: 360
    )
    @connection.update_column(:next_scheduled_sync_at, now - 1.minute)

    result = OwnedLibrarySyncRequest.call(
      connection: @connection,
      mode: :scheduled,
      now: now
    )

    assert_equal :queued, result.status
    assert_equal now - 1.minute, @connection.reload.next_scheduled_sync_at
  end

  test "an active backup blocks both manual and scheduled sync claims" do
    item = @connection.owned_library_items.create!(external_id: "B012345678", title: "A Title")
    item.owned_media_imports.create!(status: "queued")

    result = OwnedLibrarySyncRequest.call(connection: @connection)

    assert_equal :backups_active, result.status
    assert_no_enqueued_jobs only: OwnedLibrarySyncJob
    assert @connection.reload.sync_status == "idle"
  end

  test "a stale companion sync is resumed with a fresh poll token" do
    old_poll_token = "old-poll-token"
    @connection.update!(
      sync_status: "syncing",
      sync_started_at: 2.minutes.ago,
      sync_job_id: @connection.sync_job_state_value(
        job_id: "sync-existing",
        poll_token: old_poll_token
      )
    )
    @connection.update_column(:updated_at, 2.minutes.ago)

    result = OwnedLibrarySyncRequest.call(connection: @connection)

    assert_equal :resume, result.status
    assert_equal "sync-existing", result.expected_sync_job_id
    assert_not_equal old_poll_token, result.poll_token
    assert_equal result.poll_token, @connection.reload.sync_poll_token
  end

  test "a scheduled recovery does not replace an unfinished queue delivery" do
    original_poll_token = "existing-queued-poll-token"
    @connection.update!(
      scheduled_sync_enabled: true,
      sync_status: "queued",
      sync_started_at: 2.minutes.ago,
      sync_job_id: @connection.sync_job_state_value(
        job_id: nil,
        poll_token: original_poll_token
      )
    )
    @connection.update_columns(
      next_scheduled_sync_at: 1.minute.ago,
      updated_at: 2.minutes.ago
    )
    result = nil
    OwnedLibrarySyncRequest.stub(:sync_job_pending?, true) do
      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        result = OwnedLibrarySyncRequest.call(
          connection: @connection,
          mode: :scheduled
        )
      end
    end

    assert_equal :active, result.status
    assert_equal original_poll_token, @connection.reload.sync_poll_token
  end

  test "a manual recovery does not supersede a still-running queue delivery" do
    original_poll_token = "manual-live-poll-token"
    @connection.update!(
      sync_status: "syncing",
      sync_started_at: 2.minutes.ago,
      sync_job_id: @connection.sync_job_state_value(
        job_id: "sync-live",
        poll_token: original_poll_token
      )
    )
    @connection.update_column(:updated_at, 2.minutes.ago)

    result = nil
    OwnedLibrarySyncRequest.stub(:sync_job_pending?, true) do
      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        result = OwnedLibrarySyncRequest.call(connection: @connection, mode: :manual)
      end
    end

    assert_equal :active, result.status
    assert_equal "sync-live", @connection.reload.sync_job_id
    assert_equal original_poll_token, @connection.sync_poll_token
  end

  test "enqueue failure becomes a durable failed state" do
    result = nil
    OwnedLibrarySyncJob.stub(:perform_later, false) do
      result = OwnedLibrarySyncRequest.call(connection: @connection)
    end

    assert_equal :enqueue_failed, result.status
    assert result.enqueue_failed?
    assert @connection.reload.failed?
    assert_nil @connection.sync_started_at
    assert_equal OwnedLibrarySyncRequest::ENQUEUE_FAILURE_MESSAGE, @connection.last_sync_error
  end

  test "a failed scheduled enqueue backs off until the next configured interval" do
    now = Time.zone.local(2026, 7, 18, 10, 0, 0)
    @connection.update!(
      scheduled_sync_enabled: true,
      scheduled_sync_interval_minutes: 360
    )
    @connection.update_column(:next_scheduled_sync_at, now - 1.minute)

    result = nil
    OwnedLibrarySyncJob.stub(:perform_later, false) do
      result = OwnedLibrarySyncRequest.call(
        connection: @connection,
        mode: :scheduled,
        now: now
      )
    end

    assert_equal :enqueue_failed, result.status
    assert @connection.reload.failed?
    assert_equal now + 360.minutes, @connection.next_scheduled_sync_at
  end

  test "rejects an unknown request mode" do
    error = assert_raises(ArgumentError) do
      OwnedLibrarySyncRequest.call(connection: @connection, mode: :unknown)
    end

    assert_match(/Unsupported owned-library sync mode/, error.message)
  end
end
