# frozen_string_literal: true

require "test_helper"

class OwnedLibraryAutomationJobTest < ActiveJob::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(enabled: true)
  end

  test "dispatches a due scheduled library sync" do
    @connection.update!(scheduled_sync_enabled: true)
    @connection.update_column(:next_scheduled_sync_at, 1.minute.ago)

    assert_enqueued_with(job: OwnedLibrarySyncJob) do
      OwnedLibraryAutomationJob.perform_now
    end

    assert @connection.reload.queued?
    assert @connection.next_scheduled_sync_at.past?
  end

  test "does not dispatch a disabled or future scheduled sync" do
    assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
      OwnedLibraryAutomationJob.perform_now
    end

    @connection.update!(scheduled_sync_enabled: true)
    assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
      OwnedLibraryAutomationJob.perform_now
    end
  end

  test "dispatches one passive backlog import per connection" do
    first_item = @connection.owned_library_items.create!(
      external_id: "B000000001",
      title: "First backlog title",
      ownership_type: "purchased"
    )
    second_item = @connection.owned_library_items.create!(
      external_id: "B000000002",
      title: "Second backlog title",
      ownership_type: "purchased"
    )
    first = first_item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )
    second = second_item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )

    assert_enqueued_with(
      job: OwnedMediaBackupJob,
      args: ->(args) { args.first == first.id && args.second.present? }
    ) do
      OwnedLibraryAutomationJob.perform_now
    end

    assert first.reload.queued?
    assert first.dispatched_at.present?
    assert second.reload.pending?
    assert_equal 1, @connection.owned_media_imports.active.count
  end

  test "a due sync takes priority over passive backlog work" do
    item = @connection.owned_library_items.create!(
      external_id: "B000000003",
      title: "Waiting backlog title",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )
    @connection.update!(scheduled_sync_enabled: true)
    @connection.update_column(:next_scheduled_sync_at, 1.minute.ago)

    assert_enqueued_jobs 1, only: OwnedLibrarySyncJob do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        OwnedLibraryAutomationJob.perform_now
      end
    end

    assert media_import.reload.pending?
    assert @connection.reload.sync_active?
  end

  test "recovers a stale automatic import with a new polling token" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "queued",
      automatic: true,
      poll_token: "old-token"
    )
    media_import.update_column(:updated_at, OwnedMediaImport::RECOVERY_GRACE_PERIOD.ago - 1.second)

    OwnedLibraryAutomationJob.stub(:backup_job_pending?, false) do
      assert_enqueued_with(
        job: OwnedMediaBackupJob,
        args: ->(args) { args.first == media_import.id && args.second.present? }
      ) do
        OwnedLibraryAutomationJob.perform_now
      end
    end

    assert_not_equal "old-token", media_import.reload.poll_token
  end

  test "recovers a stale manual upload retry with its backup watchdog" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "A manually retried title",
      ownership_type: "purchased"
    )
    upload = Upload.create!(
      user: users(:two),
      original_filename: "retried.m4b",
      file_path: "/tmp/retried.m4b",
      status: :pending
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: upload,
      status: "processing",
      automatic: false,
      poll_token: "old-token"
    )
    media_import.update_column(:updated_at, OwnedMediaImport::RECOVERY_GRACE_PERIOD.ago - 1.second)

    OwnedLibraryAutomationJob.stub(:backup_job_pending?, false) do
      assert_enqueued_with(
        job: OwnedMediaBackupJob,
        args: ->(args) { args.first == media_import.id && args.second.present? }
      ) do
        OwnedLibraryAutomationJob.perform_now
      end
    end

    assert_not_equal "old-token", media_import.reload.poll_token
    assert media_import.processing?
  end

  test "does not recover terminal automatic imports" do
    item = @connection.owned_library_items.create!(external_id: "B012345678", title: "A Title")
    media_import = item.owned_media_imports.create!(status: "failed", automatic: true)
    media_import.update_column(:updated_at, 1.hour.ago)

    OwnedLibraryAutomationJob.stub(:backup_job_pending?, false) do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        OwnedLibraryAutomationJob.perform_now
      end
    end
  end

  test "does not duplicate an unfinished backup job" do
    item = @connection.owned_library_items.create!(external_id: "B012345678", title: "A Title")
    media_import = item.owned_media_imports.create!(status: "queued", automatic: true)
    media_import.update_column(:updated_at, 1.hour.ago)

    OwnedLibraryAutomationJob.stub(:backup_job_pending?, true) do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        OwnedLibraryAutomationJob.perform_now
      end
    end
  end
end
