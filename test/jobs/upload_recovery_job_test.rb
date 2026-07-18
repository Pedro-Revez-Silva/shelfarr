# frozen_string_literal: true

require "test_helper"

class UploadRecoveryJobTest < ActiveJob::TestCase
  setup do
    @upload = Upload.create!(
      user: users(:two),
      original_filename: "stranded.epub",
      file_path: "/tmp/stranded.epub",
      status: :processing
    )
    make_stale(@upload)
  end

  test "requeues a stale ordinary upload after confirming no worker is active" do
    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_enqueued_with(job: UploadProcessingJob, args: [ @upload.id ]) do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.pending?
    assert_nil @upload.error_message
  end

  test "two watchdog deliveries can only recover the upload once" do
    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_enqueued_jobs 1, only: UploadProcessingJob do
        2.times { UploadRecoveryJob.perform_now }
      end
    end

    assert @upload.reload.pending?
  end

  test "dispatches a stale pending upload left behind before its first enqueue" do
    @upload.update_column(:status, Upload.statuses[:pending])
    make_stale(@upload)

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_enqueued_with(job: UploadProcessingJob, args: [ @upload.id ]) do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.pending?
    assert @upload.updated_at > UploadRecoveryJob::RECOVERY_GRACE_PERIOD.ago
  end

  test "does not duplicate a queued job for a stale pending upload" do
    @upload.update_column(:status, Upload.statuses[:pending])
    make_stale(@upload)

    UploadRecoveryJob.stub(:processing_job_pending?, true) do
      assert_no_enqueued_jobs only: UploadProcessingJob do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.pending?
  end

  test "does not reset a stale upload while its processing job is active" do
    UploadRecoveryJob.stub(:processing_job_pending?, true) do
      assert_no_enqueued_jobs only: UploadProcessingJob do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.processing?
  end

  test "does not recover a recent processing upload" do
    @upload.touch

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_no_enqueued_jobs only: UploadProcessingJob do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.processing?
  end

  test "leaves every Audible upload to its owned-media watchdog" do
    connection = OwnedLibraryConnection.create!(enabled: true)
    item = connection.owned_library_items.create!(
      external_id: "B0OWNEDWATCHDOG",
      title: "Owned title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: @upload,
      status: "processing"
    )

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_no_enqueued_jobs only: UploadProcessingJob do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.processing?
  end

  test "leaves a rejected recovery pending for the pending-upload watchdog" do
    failed_job = Struct.new(:successfully_enqueued?).new(false)
    original_updated_at = @upload.updated_at

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      UploadProcessingJob.stub(:set, ->(*) { StubConfiguredJob.new(failed_job) }) do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.pending?
    assert_operator @upload.updated_at, :>, original_updated_at
  end

  test "commits pending state before dispatching the recovery job" do
    observed_status = nil
    configured_job = Object.new
    configured_job.define_singleton_method(:perform_later) do |upload_id|
      observed_status = Upload.find(upload_id).status
      Struct.new(:successfully_enqueued?).new(true)
    end

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      UploadProcessingJob.stub(:set, configured_job) do
        UploadRecoveryJob.perform_now
      end
    end

    assert_equal "pending", observed_status
  end

  test "requeues an interrupted ZIP upload for manifest-based recovery" do
    @upload.update!(
      original_filename: "interrupted.zip",
      book_type: :audiobook
    )
    make_stale(@upload)

    UploadRecoveryJob.stub(:processing_job_pending?, false) do
      assert_enqueued_with(job: UploadProcessingJob, args: [ @upload.id ]) do
        UploadRecoveryJob.perform_now
      end
    end

    assert @upload.reload.pending?
    assert_nil @upload.error_message
  end

  private

  StubConfiguredJob = Struct.new(:result) do
    def perform_later(*)
      result
    end
  end

  def make_stale(upload)
    upload.update_column(
      :updated_at,
      UploadRecoveryJob::RECOVERY_GRACE_PERIOD.ago - 1.second
    )
    upload.reload
  end
end
