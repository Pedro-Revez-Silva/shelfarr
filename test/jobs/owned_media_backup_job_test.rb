# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OwnedMediaBackupJobTest < ActiveJob::TestCase
  setup do
    @audiobook_output = Dir.mktmpdir("owned-media-audiobooks")
    SettingsService.set(:audiobook_output_path, @audiobook_output)
    @connection = OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "token",
      enabled: true
    )
    @item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )
    @media_import = @item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "queued"
    )
    clear_enqueued_jobs
  end

  teardown do
    FileUtils.rm_rf(@audiobook_output) if @audiobook_output
  end

  test "starts a targeted backup and schedules polling" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "backup-1", status: "queued" }.to_json)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    @media_import.reload
    assert_equal "queued", @media_import.status
    assert_equal "backup-1", @media_import.external_job_id
    assert_nil @media_import.started_at
  end

  test "retries an ambiguous companion start and reattaches to the idempotent job" do
    VCR.turned_off do
      failed_request = stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_raise(Errno::ECONNRESET)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
      end

      assert_requested failed_request, times: 1
      @media_import.reload
      assert @media_import.starting?
      assert_nil @media_import.external_job_id
      assert_equal 1, @media_import.companion_start_attempts
      assert_match(/retry automatically/, @media_import.error_message)

      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "backup-1", status: "queued" }.to_json)
      clear_enqueued_jobs

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        OwnedMediaBackupJob.perform_now(@media_import.id, @media_import.poll_token)
      end

      assert_requested :post, "https://libation.test/v1/backups/B012345678", times: 2
    end

    @media_import.reload
    assert @media_import.queued?
    assert_equal "backup-1", @media_import.external_job_id
    assert_equal 2, @media_import.companion_start_attempts
    assert_nil @media_import.error_message
  end

  test "retries a busy companion before a backup job id is available" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 429, body: { error: "queue full" }.to_json)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
      end
    end

    @media_import.reload
    assert @media_import.active?
    assert_equal 1, @media_import.companion_start_attempts
    assert_match(/retry automatically/, @media_import.error_message)
  end

  test "fails after the bounded companion start retry budget is exhausted" do
    @media_import.update!(
      companion_start_attempts: OwnedMediaBackupJob::MAX_COMPANION_START_ATTEMPTS - 1
    )

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_raise(Errno::ECONNRESET)

      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        assert_raises(OwnedMediaBackupJob::BackupError) do
          OwnedMediaBackupJob.perform_now(@media_import.id)
        end
      end
    end

    @media_import.reload
    assert @media_import.failed?
    assert_equal OwnedMediaBackupJob::MAX_COMPANION_START_ATTEMPTS,
      @media_import.companion_start_attempts
    assert_match(/after 3 attempts/, @media_import.error_message)
  end

  test "marks a running companion backup as downloading" do
    @media_import.update!(external_job_id: "backup-1")

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "running" }.to_json)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    assert @media_import.reload.downloading?
    assert @media_import.started_at.present?
  end

  test "retries a transient companion polling outage without failing the import" do
    @media_import.update!(external_job_id: "backup-1")

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_raise(Errno::ECONNRESET)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
      end
    end

    @media_import.reload
    assert @media_import.active?
    assert_match(/retry automatically/, @media_import.error_message)
  end

  test "retry reattaches to the same active companion job" do
    previous = @item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "failed",
      external_job_id: "backup-1",
      completed_at: 1.minute.ago
    )

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "backup-1", status: "queued" }.to_json)

      OwnedMediaBackupJob.perform_now(@media_import.id)
    end

    assert_nil previous.reload.external_job_id
    assert_equal "backup-1", @media_import.reload.external_job_id
    assert @media_import.queued?
  end

  test "time spent waiting in the companion queue does not consume the backup timeout" do
    @media_import.update!(external_job_id: "backup-1", started_at: nil, created_at: 2.days.ago)

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "queued" }.to_json)

      assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
    end

    assert @media_import.reload.queued?
    assert_nil @media_import.started_at
  end

  test "a healthy unchanged companion poll refreshes the recovery heartbeat" do
    @media_import.update!(external_job_id: "backup-1", updated_at: 5.minutes.ago)

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "queued" }.to_json)

      OwnedMediaBackupJob.perform_now(@media_import.id)
    end

    @media_import.reload
    assert @media_import.updated_at > 1.minute.ago
    assert_not @media_import.recoverable?
  end

  test "an old poll token cannot create a second polling chain after recovery" do
    @media_import.update!(external_job_id: "backup-1", updated_at: 5.minutes.ago)
    stale_token = @media_import.updated_at.utc.iso8601(6)
    @media_import.touch

    VCR.turned_off do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        OwnedMediaBackupJob.perform_now(@media_import.id, stale_token)
      end
      assert_not_requested :get, "https://libation.test/v1/jobs/backup-1"
    end
  end

  test "an enqueued successor self-promotes when its parent exits before handoff" do
    current_token = OwnedMediaImport.generate_poll_token
    successor = OwnedMediaImport.next_poll_token(current_token)
    @media_import.update!(
      external_job_id: "backup-1",
      poll_token: current_token
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "queued" }.to_json)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        OwnedMediaBackupJob.perform_now(@media_import.id, successor)
      end
    end

    assert_equal OwnedMediaImport.next_poll_token(successor), @media_import.reload.poll_token
  end

  test "a companion queue older than seven days becomes retryable instead of blocking forever" do
    @media_import.update!(
      external_job_id: "backup-1",
      started_at: nil,
      created_at: 8.days.ago
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "queued" }.to_json)

      assert_raises(OwnedMediaBackupJob::BackupError) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    assert @media_import.reload.failed?
    assert_match(/more than 7 days/, @media_import.error_message)
  end

  test "passive backlog age does not consume the seven day dispatch window" do
    @media_import.update!(
      external_job_id: "backup-1",
      started_at: nil,
      created_at: 8.days.ago,
      dispatched_at: 1.minute.ago
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/backup-1")
        .to_return(status: 200, body: { id: "backup-1", status: "queued" }.to_json)

      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    assert @media_import.reload.queued?
    assert_nil @media_import.error_message
  end

  test "marks the import failed when the next delayed check cannot be queued" do
    failed_enqueue = Struct.new(:successfully_enqueued?).new(false)
    scheduler = Object.new
    scheduler.define_singleton_method(:perform_later) { |*| failed_enqueue }

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "backup-1", status: "queued" }.to_json)

      OwnedMediaBackupJob.stub(:set, scheduler) do
        assert_raises(OwnedMediaBackupJob::BackupError) do
          OwnedMediaBackupJob.perform_now(@media_import.id)
        end
      end
    end

    assert @media_import.reload.failed?
    assert_match(/could not queue/, @media_import.error_message)
  end

  test "copies a completed artifact from the shared import root without consuming the backup" do
    Dir.mktmpdir("libation-import") do |root|
      source_dir = File.join(root, "Author")
      FileUtils.mkdir_p(source_dir)
      source = File.join(source_dir, "A Title.m4b")
      File.binwrite(source, "audio")

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        VCR.turned_off do
          stub_request(:post, "https://libation.test/v1/backups/B012345678")
            .to_return(
              status: 202,
              body: {
                jobId: "backup-1",
                status: "completed",
                artifactPath: "/data/Author/A Title.m4b"
              }.to_json
            )

          assert_difference -> { Upload.count }, 1 do
            assert_enqueued_with(job: OwnedMediaBackupJob) do
              assert_enqueued_with(job: UploadProcessingJob) do
                OwnedMediaBackupJob.perform_now(@media_import.id)
              end
            end
          end
        end
      end

      assert File.exist?(source), "Libation's preserved backup must not be moved"
      @media_import.reload
      assert @media_import.processing?
      assert_equal File.realpath(source), @media_import.artifact_path
      assert File.exist?(@media_import.upload.file_path)
    ensure
      upload_path = @media_import.reload.upload&.file_path
      FileUtils.rm_f(upload_path) if upload_path.present?
    end
  end

  test "artifact staging SQL logs exclude personal Audible paths and metadata" do
    secret_title = "Private Backup Title #{SecureRandom.hex(4)}"
    secret_author = "Private Backup Author #{SecureRandom.hex(4)}"
    @item.update!(
      title: secret_title,
      authors: [ secret_author ],
      cover_url: "https://m.media-amazon.com/images/I/private-backup.jpg"
    )

    Dir.mktmpdir("private-libation-import") do |root|
      secret_filename = "#{SecureRandom.hex(8)}-private-title.m4b"
      source = File.join(root, secret_filename)
      File.binwrite(source, "private audio")

      logs = with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        VCR.turned_off do
          stub_request(:post, "https://libation.test/v1/backups/B012345678")
            .to_return(status: 202, body: {
              jobId: "backup-private",
              status: "completed",
              artifactPath: "/data/#{secret_filename}"
            }.to_json)

          capture_owned_job_logs do
            OwnedMediaBackupJob.perform_now(@media_import.id)
          end
        end
      end.join("\n")

      assert @media_import.reload.processing?
      [ secret_title, secret_author, secret_filename, source ].each do |secret|
        assert_not_includes logs, secret
      end
    ensure
      FileUtils.rm_f(@media_import.reload.upload&.file_path)
    end
  end

  test "completed artifact staging is idempotent for a redelivered poll" do
    Dir.mktmpdir("libation-import") do |root|
      source = File.join(root, "A Title.m4b")
      File.binwrite(source, "audio")
      companion_job = LibationCompanionClient::CompanionJob.new(
        "backup-1",
        "completed",
        [ "/data/A Title.m4b" ],
        nil,
        {}
      )
      job = OwnedMediaBackupJob.new
      job.instance_variable_set(:@poll_token, @media_import.claim_poll_token)

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        assert_difference -> { Upload.count }, 1 do
          job.send(:stage_completed_artifact, @media_import, companion_job)
          job.send(:stage_completed_artifact, @media_import.reload, companion_job)
        end
      end

      assert @media_import.reload.processing?
      assert_equal 1, enqueued_jobs.count { |payload| payload[:job] == OwnedMediaBackupJob }
      assert_equal 1, enqueued_jobs.count { |payload| payload[:job] == UploadProcessingJob }
    ensure
      upload_path = @media_import.reload.upload&.file_path
      FileUtils.rm_f(upload_path) if upload_path.present?
    end
  end

  test "copies from the held artifact descriptor when the shared path is swapped" do
    Dir.mktmpdir("libation-import") do |root|
      source = File.join(root, "A Title.m4b")
      outside = File.join(File.dirname(root), "outside-audio-#{SecureRandom.hex(4)}.m4b")
      File.binwrite(source, "trusted audio")
      File.binwrite(outside, "outside bytes")
      original_copy = OwnedMediaImportFileService.method(:copy_io_contents)
      companion_job = LibationCompanionClient::CompanionJob.new(
        "backup-1",
        "completed",
        [ "/data/A Title.m4b" ],
        nil,
        {}
      )
      job = OwnedMediaBackupJob.new
      job.instance_variable_set(:@poll_token, @media_import.claim_poll_token)

      swap_then_copy = lambda do |descriptor, destination|
        File.unlink(source)
        File.symlink(outside, source)
        original_copy.call(descriptor, destination)
      end

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        OwnedMediaImportFileService.stub(:copy_io_contents, swap_then_copy) do
          job.send(:stage_completed_artifact, @media_import, companion_job)
        end
      end

      upload_path = @media_import.reload.upload.file_path
      assert_equal "trusted audio", File.binread(upload_path)
      assert_equal "outside bytes", File.binread(source)
    ensure
      upload_path = @media_import.reload.upload&.file_path
      FileUtils.rm_f(upload_path) if upload_path.present?
      FileUtils.rm_f(outside) if outside
    end
  end

  test "an upload-processing enqueue failure leaves the import recoverable by its poll" do
    Dir.mktmpdir("libation-import") do |root|
      source = File.join(root, "A Title.m4b")
      File.binwrite(source, "audio")
      companion_job = LibationCompanionClient::CompanionJob.new(
        "backup-1",
        "completed",
        [ "/data/A Title.m4b" ],
        nil,
        {}
      )
      enqueue_failure = ->(*) { raise ActiveJob::EnqueueError, "queue unavailable" }
      job = OwnedMediaBackupJob.new
      job.instance_variable_set(:@poll_token, @media_import.claim_poll_token)

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        UploadProcessingJob.stub(:perform_later, enqueue_failure) do
          assert_nothing_raised do
            job.send(
              :stage_completed_artifact,
              @media_import,
              companion_job
            )
          end
        end
      end

      @media_import.reload
      assert @media_import.processing?
      assert @media_import.upload.pending?
      assert_enqueued_with(job: OwnedMediaBackupJob, args: poll_args)
    ensure
      upload_path = @media_import.reload.upload&.file_path
      FileUtils.rm_f(upload_path) if upload_path.present?
    end
  end

  test "rejects an absolute artifact outside companion data root" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(
          status: 202,
          body: { jobId: "backup-1", status: "completed", artifactPath: "/etc/passwd" }.to_json
        )

      assert_raises(OwnedMediaBackupJob::BackupError) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    assert @media_import.reload.failed?
    assert_match(/outside its data directory/, @media_import.error_message)
  end

  test "rejects a companion-reported FIFO without blocking the worker" do
    skip "mkfifo is unavailable" unless File.respond_to?(:mkfifo)

    Dir.mktmpdir("libation-import") do |root|
      fifo = File.join(root, "A Title.m4b")
      File.mkfifo(fifo, 0o600)
      companion_job = LibationCompanionClient::CompanionJob.new(
        "backup-1",
        "completed",
        [ "/data/A Title.m4b" ],
        nil,
        {}
      )
      job = OwnedMediaBackupJob.new
      job.instance_variable_set(:@poll_token, @media_import.claim_poll_token)

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        error = assert_raises(OwnedMediaBackupJob::BackupError) do
          job.send(:stage_completed_artifact, @media_import, companion_job)
        end
        assert_match(/regular audiobook file/, error.message)
      end
    end
  end

  test "rejects ambiguous multipart audio and requires companion one-file output" do
    Dir.mktmpdir("libation-import") do |root|
      book_dir = File.join(root, "Book")
      FileUtils.mkdir_p(book_dir)
      File.binwrite(File.join(book_dir, "part-1.mp3"), "one")
      File.binwrite(File.join(book_dir, "part-2.mp3"), "two")

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        VCR.turned_off do
          stub_request(:post, "https://libation.test/v1/backups/B012345678")
            .to_return(
              status: 202,
              body: { jobId: "backup-1", status: "completed", artifactPath: "/data/Book" }.to_json
            )

          assert_raises(OwnedMediaBackupJob::BackupError) do
            OwnedMediaBackupJob.perform_now(@media_import.id)
          end
        end
      end
    end

    assert @media_import.reload.failed?
    assert_match(/single primary artifact/, @media_import.error_message)
  end

  test "finishes after Shelfarr upload processing completes" do
    upload = Upload.create!(
      user: users(:two),
      book: books(:audiobook_acquired),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "completed-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :completed,
      processed_at: Time.current
    )
    @media_import.update!(status: "processing", started_at: 1.minute.ago, upload: upload)

    OwnedMediaBackupJob.perform_now(@media_import.id)

    assert @media_import.reload.completed?
    assert @item.reload.downloaded?
    assert_equal books(:audiobook_acquired), @item.book
    assert_equal books(:audiobook_acquired).file_path, @item.file_path
  end

  test "requeues a pending upload if the original processing enqueue was lost" do
    upload = Upload.create!(
      user: users(:two),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "pending-libation-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :pending
    )
    @media_import.update!(status: "processing", started_at: 1.minute.ago, upload: upload)

    assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
      OwnedMediaBackupJob.perform_now(@media_import.id)
    end
  end

  test "does not amplify upload processing while an unfinished job already exists" do
    upload = Upload.create!(
      user: users(:two),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "pending-libation-dedup-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :pending
    )
    @media_import.update!(status: "processing", started_at: 1.minute.ago, upload: upload)

    OwnedMediaBackupJob.stub(:upload_processing_job_pending?, true) do
      assert_no_enqueued_jobs only: UploadProcessingJob do
        OwnedMediaBackupJob.perform_now(@media_import.id)
        OwnedMediaBackupJob.perform_now(@media_import.id, @media_import.reload.poll_token)
      end
    end

    assert upload.reload.pending?
    assert_equal 2, enqueued_jobs.count { |payload| payload[:job] == OwnedMediaBackupJob }
  end

  test "treats a Solid Queue inspection failure as an unfinished upload job" do
    queue_failure = lambda do |*|
      raise ActiveRecord::StatementInvalid, "queue unavailable"
    end

    OwnedMediaBackupJob.stub(:solid_queue_adapter?, true) do
      SolidQueue::Job.stub(:where, queue_failure) do
        assert OwnedMediaBackupJob.upload_processing_job_pending?(123)
      end
    end
  end

  test "detects an unfinished upload processing job persisted in Solid Queue" do
    with_solid_queue_upload_processing_jobs do |processing_jobs|
      UploadProcessingJob.set(wait: 1.minute).perform_later(123_456_789)

      assert_equal 1, processing_jobs.count
      assert OwnedMediaBackupJob.upload_processing_job_pending?(123_456_789)
      assert_not OwnedMediaBackupJob.upload_processing_job_pending?(987_654_321)

      processing_jobs.first.update!(finished_at: Time.current)
      assert_not OwnedMediaBackupJob.upload_processing_job_pending?(123_456_789)
    end
  end

  test "resets and requeues a stale processing upload" do
    upload = Upload.create!(
      user: users(:two),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "stale-processing-libation-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :processing,
      updated_at: 31.minutes.ago
    )
    @media_import.update!(status: "processing", started_at: 1.hour.ago, upload: upload)

    assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
      OwnedMediaBackupJob.perform_now(@media_import.id)
    end

    assert upload.reload.pending?
    assert_not @media_import.reload.recoverable?
  end

  test "reconciles a stale processing upload before applying the import timeout" do
    upload = Upload.create!(
      user: users(:two),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "stale-finalized-libation-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :processing,
      updated_at: 13.hours.ago
    )
    @media_import.update!(status: "processing", started_at: 13.hours.ago, upload: upload)

    assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
      assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
    end

    assert upload.reload.pending?
    assert @media_import.reload.active?
    assert @media_import.started_at > 1.minute.ago
    assert_equal 1, @media_import.upload_recovery_attempts
  end

  test "a second stale upload cannot renew the recovery timeout indefinitely" do
    upload = Upload.create!(
      user: users(:two),
      original_filename: "A Title.m4b",
      file_path: Rails.root.join("tmp", "repeated-stale-libation-test.m4b").to_s,
      file_size: 1,
      content_type: "audio/mp4",
      status: :processing,
      updated_at: 13.hours.ago
    )
    @media_import.update!(
      status: "processing",
      started_at: 13.hours.ago,
      upload: upload,
      upload_recovery_attempts: 1
    )

    assert_no_enqueued_jobs only: UploadProcessingJob do
      assert_raises(OwnedMediaBackupJob::BackupError) do
        OwnedMediaBackupJob.perform_now(@media_import.id)
      end
    end

    assert @media_import.reload.failed?
    assert_equal 1, @media_import.upload_recovery_attempts
  end

  test "does not back up titles that are not confirmed as purchased" do
    @item.update!(ownership_type: "subscription")

    assert_raises(OwnedMediaBackupJob::BackupError) do
      OwnedMediaBackupJob.perform_now(@media_import.id)
    end

    assert @media_import.reload.failed?
    assert_match(/confirmed as purchased/, @media_import.error_message)
  end

  test "an explicit separate-edition choice may proceed past an ambiguous local match" do
    Book.create!(
      title: "A Title",
      author: "An Author",
      narrator: "A Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/a-title"
    )
    @item.update!(authors: [ "An Author" ], narrators: [ "A Narrator" ])
    @media_import.update!(separate_edition: true)

    VCR.turned_off do
      backup_request = stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "backup-separate", status: "queued" }.to_json)

      assert_nothing_raised { OwnedMediaBackupJob.perform_now(@media_import.id) }
      assert_requested backup_request
    end

    assert_equal "backup-separate", @media_import.reload.external_job_id
  end

  test "unexpected copy failures persist a safe error without the source path" do
    Dir.mktmpdir("libation-import") do |root|
      source = File.join(root, "A Title.m4b")
      File.binwrite(source, "audio")

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => root) do
        VCR.turned_off do
          stub_request(:post, "https://libation.test/v1/backups/B012345678")
            .to_return(
              status: 202,
              body: { jobId: "backup-1", status: "completed", artifactPath: "/data/A Title.m4b" }.to_json
            )

          OwnedMediaImportFileService.stub(:copy_io_contents, ->(*) { raise Errno::EIO, source }) do
            assert_raises(Errno::EIO) { OwnedMediaBackupJob.perform_now(@media_import.id) }
          end
        end
      end
    end

    assert_equal "Unexpected Errno::EIO while importing the Libation backup",
      @media_import.reload.error_message
  end

  private

  def with_solid_queue_upload_processing_jobs
    original_adapter = ActiveJob::Base.queue_adapter
    original_config = SolidQueue::Record.connection_db_config
    processing_jobs = nil

    SolidQueue::Record.establish_connection(:queue)
    ActiveJob::Base.queue_adapter = :solid_queue
    processing_jobs = SolidQueue::Job.where(class_name: UploadProcessingJob.name)
    processing_jobs.destroy_all

    yield processing_jobs.where(finished_at: nil)
  ensure
    processing_jobs&.destroy_all
    ActiveJob::Base.queue_adapter = original_adapter
    SolidQueue::Record.establish_connection(original_config)
  end

  def poll_args
    lambda do |args|
      args.first == @media_import.id && args.second.present?
    end
  end

  def capture_owned_job_logs(&job)
    original_rails_logger = Rails.logger
    original_database_logger = ActiveRecord::Base.logger
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    logger.level = Logger::DEBUG
    Rails.logger = logger
    ActiveRecord::Base.logger = logger

    job.call
    output.string.lines(chomp: true)
  ensure
    ActiveRecord::Base.logger = original_database_logger
    Rails.logger = original_rails_logger
  end
end
