# frozen_string_literal: true

require "test_helper"

class PostProcessingRecoveryJobTest < ActiveJob::TestCase
  setup do
    @book = Book.create!(title: "Recoverable import", book_type: :ebook)
    @request = Request.create!(
      book: @book,
      user: users(:one),
      status: :processing
    )
    @download = @request.downloads.create!(
      name: "Recoverable import",
      status: :completed,
      download_path: "/downloads/recoverable-import",
      post_processing_job_id: "stale-owner"
    )
    make_stale(@download)
  end

  test "transfers a stale durable owner before enqueueing its recovery" do
    retry_args = ->(args) { args == [ @download.id, 0, "stale-owner" ] }

    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
        PostProcessingRecoveryJob.perform_now
      end

      assert_equal retry_job.job_id, @download.reload.post_processing_job_id
      assert @download.updated_at > PostProcessingRecoveryJob::RECOVERY_GRACE_PERIOD.ago
    end
  end

  test "recovers the initial completed-to-enqueue crash gap" do
    @download.update_column(:post_processing_job_id, nil)
    make_stale(@download)
    retry_args = ->(args) { args == [ @download.id, 0, nil ] }

    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
        PostProcessingRecoveryJob.perform_now
      end

      assert_equal retry_job.job_id, @download.reload.post_processing_job_id
    end
  end

  test "does not supersede a live or scheduled post-processing job" do
    previous_updated_at = @download.updated_at
    PostProcessingRecoveryJob.stub(:processing_job_pending?, true) do
      assert_no_enqueued_jobs only: PostProcessingJob do
        PostProcessingRecoveryJob.perform_now
      end
    end

    assert_equal "stale-owner", @download.reload.post_processing_job_id
    assert @download.updated_at > previous_updated_at
  end

  test "queue inspection recognizes a scheduled Solid Queue delivery" do
    with_solid_queue_post_processing_jobs do
      PostProcessingJob.set(wait: 1.hour).perform_later(
        @download.id,
        1,
        "stale-owner"
      )

      assert PostProcessingRecoveryJob.processing_job_pending?(@download.id)
    end
  end

  test "two watchdog deliveries transfer and enqueue an owner only once" do
    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      assert_enqueued_jobs 1, only: PostProcessingJob do
        2.times { PostProcessingRecoveryJob.perform_now }
      end
    end
  end

  test "does not recover a recent owner" do
    @download.touch

    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      assert_no_enqueued_jobs only: PostProcessingJob do
        PostProcessingRecoveryJob.perform_now
      end
    end

    assert_equal "stale-owner", @download.reload.post_processing_job_id
  end

  test "handled failures wait for an explicit retry instead of looping forever" do
    @request.update!(attention_needed: true, issue_description: "Safe failure")

    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      assert_no_enqueued_jobs only: PostProcessingJob do
        PostProcessingRecoveryJob.perform_now
      end
    end

    retry_args = ->(args) { args == [ @download.id, 0, "stale-owner" ] }
    retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      assert_equal :post_processing_queued, @request.retry_now!
    end

    assert @request.reload.processing?
    assert_not @request.attention_needed?
    assert_nil @request.issue_description
    assert_equal retry_job.job_id, @download.reload.post_processing_job_id

    SettingsService.set(:post_processing_source_path_retries, 0)
    retry_job.perform_now

    assert @request.reload.attention_needed?
    assert_match(/source path not found/i, @request.issue_description)
    assert_equal retry_job.job_id, @download.reload.post_processing_job_id
  end

  test "watchdog repairs the durable owner after a manual retry enqueue failure" do
    @request.update!(attention_needed: true, issue_description: "Safe failure")
    failed_job = PostProcessingJob.new(@download.id, 0, "stale-owner")

    outcome = PostProcessingJob.stub(:new, failed_job) do
      failed_job.stub(:enqueue, false) { @request.retry_now! }
    end

    assert_equal :post_processing_recovery_pending, outcome
    assert_not @request.reload.attention_needed?
    assert_nil @request.issue_description
    assert_equal failed_job.job_id, @download.reload.post_processing_job_id

    make_stale(@download)
    retry_args = ->(args) { args == [ @download.id, 0, failed_job.job_id ] }
    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
        PostProcessingRecoveryJob.perform_now
      end

      assert_equal retry_job.job_id, @download.reload.post_processing_job_id
    end
  end

  test "does not recover a cancelled or completed request" do
    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      [ :failed, :completed ].each do |status|
        @request.update!(status: status)
        make_stale(@download)

        assert_no_enqueued_jobs only: PostProcessingJob do
          PostProcessingRecoveryJob.perform_now
        end
      end
    end

    assert_equal "stale-owner", @download.reload.post_processing_job_id
  end

  test "does not recover while another acquisition owns request admission" do
    upload = Upload.create!(
      user: users(:one),
      request: @request,
      original_filename: "competing.epub",
      file_path: "/tmp/competing.epub",
      status: :pending
    )

    PostProcessingRecoveryJob.stub(:processing_job_pending?, false) do
      assert_no_enqueued_jobs only: PostProcessingJob do
        PostProcessingRecoveryJob.perform_now
      end
    end

    assert upload.reload.pending?
    assert_equal "stale-owner", @download.reload.post_processing_job_id
  end

  test "queue inspection fails closed" do
    PostProcessingRecoveryJob.stub(:solid_queue_adapter?, true) do
      SolidQueue::Job.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
        assert PostProcessingRecoveryJob.processing_job_pending?(@download.id)
      end
    end
  end

  private

  def with_solid_queue_post_processing_jobs
    original_adapter = ActiveJob::Base.queue_adapter
    original_config = SolidQueue::Record.connection_db_config
    processing_jobs = nil

    SolidQueue::Record.establish_connection(:queue)
    ActiveJob::Base.queue_adapter = :solid_queue
    processing_jobs = SolidQueue::Job.where(class_name: PostProcessingJob.name)
    processing_jobs.destroy_all

    yield
  ensure
    processing_jobs&.destroy_all
    ActiveJob::Base.queue_adapter = original_adapter
    SolidQueue::Record.establish_connection(original_config)
  end

  def make_stale(download)
    download.update_column(
      :updated_at,
      PostProcessingRecoveryJob::RECOVERY_GRACE_PERIOD.ago - 1.minute
    )
  end
end
