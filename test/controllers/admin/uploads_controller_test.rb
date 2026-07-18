# frozen_string_literal: true

require "test_helper"

class Admin::UploadsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:two)
    sign_in_as(@admin)
  end

  test "index requires admin" do
    delete session_url
    get admin_uploads_url
    assert_response :redirect
  end

  test "index shows uploads" do
    upload = Upload.create!(
      user: users(:one),
      original_filename: "shared-book.epub",
      file_path: "/tmp/shared-book.epub",
      status: :pending
    )

    get admin_uploads_url

    assert_response :success
    assert_select "th", "Uploaded By"
    assert_select "div", text: upload.user.name
  end

  test "new shows upload form" do
    get new_admin_upload_url
    assert_response :success
    assert_select "input[type='file'][name='files[]'][multiple]"
  end

  test "new shows request upload context" do
    request = requests(:pending_request)

    get new_admin_upload_url(request_id: request.id)

    assert_response :success
    assert_select "input[name='request_id'][value='#{request.id}']"
    assert_select "input[type='file'][name='file']"
    assert_select "h2", "Fulfill Request"
    assert_select "p", text: /#{request.book.display_name}/
  end

  test "new redirects away from completed request upload context" do
    request = requests(:pending_request)
    request.complete!

    get new_admin_upload_url(request_id: request.id)

    assert_redirected_to request_path(request)
    assert_equal "This request is already completed.", flash[:alert]
  end

  test "create with valid file starts processing" do
    file = fixture_file_upload("test_audiobook.m4b", "audio/mp4")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post admin_uploads_url,
          params: { file: file },
          headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
      end
    end

    assert_redirected_to admin_uploads_path
    assert_equal "File uploaded successfully. Processing started.", flash[:notice]
  end

  test "create records a retryable failure when initial queueing is rejected" do
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    UploadProcessingJob.stub(:perform_later, false) do
      assert_difference "Upload.count", 1 do
        post admin_uploads_url, params: { file: file }
      end
    end

    upload = Upload.order(:created_at).last
    assert_redirected_to new_admin_upload_path
    assert_match(/could not be queued/, flash[:alert])
    assert upload.failed?
    assert File.exist?(upload.file_path)
  ensure
    FileUtils.rm_f(upload&.file_path)
  end

  test "create records a retryable failure when initial queueing raises" do
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")
    failure = ->(*) { raise ActiveJob::EnqueueError, "queue unavailable" }

    UploadProcessingJob.stub(:perform_later, failure) do
      post admin_uploads_url, params: { file: file }
    end

    upload = Upload.order(:created_at).last
    assert_redirected_to new_admin_upload_path
    assert_match(/could not be queued/, flash[:alert])
    assert upload.failed?
  ensure
    FileUtils.rm_f(upload&.file_path)
  end

  test "create with multiple files starts processing each file" do
    audiobook = fixture_file_upload("test_audiobook.m4b", "audio/mp4")
    ebook = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 2 do
      assert_enqueued_jobs 2, only: UploadProcessingJob do
        post admin_uploads_url, params: { files: [ audiobook, ebook ] }
      end
    end

    assert_redirected_to admin_uploads_path
    assert_equal "2 files uploaded successfully. Processing started.", flash[:notice]
  end

  test "create from folder skips unsupported files" do
    audiobook = fixture_file_upload("test_audiobook.m4b", "audio/mp4")
    text = fixture_file_upload("test.txt", "text/plain")

    assert_difference "Upload.count", 1 do
      assert_enqueued_jobs 1, only: UploadProcessingJob do
        post admin_uploads_url, params: { files: [ audiobook, text ], upload_mode: "folder" }
      end
    end

    assert_redirected_to admin_uploads_path
    assert_equal "1 file uploaded successfully. Processing started.", flash[:notice]
    assert_nil flash[:alert]
  end

  test "create with request rejects multiple files" do
    request = requests(:pending_request)
    first_file = fixture_file_upload("test_ebook.epub", "application/epub+zip")
    second_file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_no_difference "Upload.count" do
      post admin_uploads_url, params: { files: [ first_file, second_file ], request_id: request.id }
    end

    assert_redirected_to new_admin_upload_path(request_id: request.id)
    assert_equal "Please upload one file when fulfilling a request", flash[:alert]
  end

  test "create with request links upload and redirects to request" do
    request = requests(:pending_request)
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post admin_uploads_url, params: { file: file, request_id: request.id }
      end
    end

    upload = Upload.order(:created_at).last
    assert_equal request, upload.request
    assert_redirected_to request_path(request)
  end

  test "create with request rejects mismatched file type" do
    request = requests(:pending_request)
    file = fixture_file_upload("test_audiobook.m4b", "audio/mp4")

    assert_no_difference "Upload.count" do
      post admin_uploads_url, params: { file: file, request_id: request.id }
    end

    assert_redirected_to new_admin_upload_path(request_id: request.id)
    assert_includes flash[:alert], "does not match"
  end

  test "create with m4a audiobook starts processing" do
    file = fixture_file_upload("test_audiobook.m4a", "audio/mp4")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post admin_uploads_url, params: { file: file }
      end
    end

    assert_redirected_to admin_uploads_path
    assert_equal "File uploaded successfully. Processing started.", flash[:notice]
  end

  test "create with ebook file starts processing" do
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 1 do
      post admin_uploads_url, params: { file: file }
    end

    assert_redirected_to admin_uploads_path
  end

  test "create rejects unsupported file types" do
    file = fixture_file_upload("test.txt", "text/plain")

    assert_no_difference "Upload.count" do
      post admin_uploads_url, params: { file: file }
    end

    assert_redirected_to new_admin_upload_path
    assert flash[:alert].present?
    assert_includes flash[:alert], "Unsupported file type"
  end

  test "create without file shows error" do
    post admin_uploads_url, params: {}

    assert_redirected_to new_admin_upload_path
    assert_equal "Please select a file to upload", flash[:alert]
  end

  test "show displays upload details" do
    upload = Upload.create!(
      user: @admin,
      original_filename: "test.m4b",
      file_path: "/tmp/test.m4b",
      status: :pending
    )

    get admin_upload_url(upload)
    assert_response :success
  end

  test "destroy removes upload" do
    upload = Upload.create!(
      user: @admin,
      original_filename: "test.m4b",
      file_path: "/tmp/nonexistent.m4b",
      status: :pending
    )

    assert_difference "Upload.count", -1 do
      delete admin_upload_url(upload),
        headers: { "HTTP_REFERER" => "http://[malformed" }
    end

    assert_redirected_to admin_uploads_path
  end

  test "destroy preserves a destination-only failed Audible import" do
    upload, media_import = create_failed_audible_import
    destination_root = Dir.mktmpdir("audible-reserved-destination")
    destination = File.join(destination_root, "Reserved Title.m4b")
    File.binwrite(destination, "owned audiobook")
    upload.update!(file_path: File.join(destination_root, "missing-staging.m4b"))
    media_import.update!(
      destination_path: destination,
      library_path: destination
    )

    assert_no_difference "Upload.count" do
      delete admin_upload_url(upload)
    end

    assert_redirected_to admin_uploads_path
    assert_match(/cannot be deleted safely/, flash[:alert])
    assert upload.reload.failed?
    assert_equal upload, media_import.reload.upload
    assert_equal "owned audiobook", File.binread(destination)
  ensure
    FileUtils.rm_rf(destination_root) if destination_root
  end

  test "destroy preserves a failed ordinary upload with an unresolved reservation" do
    root = Dir.mktmpdir("ordinary-reserved-destination")
    source = File.join(root, "source.epub")
    destination = File.join(root, "library", "reserved.epub")
    File.binwrite(source, "reserved upload")
    upload = Upload.create!(
      user: @admin,
      original_filename: "reserved.epub",
      file_path: source,
      file_size: File.size(source),
      status: :failed,
      destination_path: destination,
      destination_root: File.realpath(root),
      destination_configured_root: root,
      library_path: destination,
      content_sha256: Digest::SHA256.file(source).hexdigest,
      cleanup_source_path: File.realpath(source)
    )

    assert_no_difference "Upload.count" do
      delete admin_upload_url(upload)
    end

    assert_redirected_to admin_uploads_path
    assert_match(/reserved library file/, flash[:alert])
    assert upload.reload.failed?
    assert_equal "reserved upload", File.binread(source)
  ensure
    FileUtils.rm_rf(root) if root
  end

  test "retry requeues failed upload" do
    upload = Upload.create!(
      user: @admin,
      original_filename: "test.m4b",
      file_path: "/tmp/test.m4b",
      status: :failed,
      error_message: "Test error"
    )

    assert_enqueued_with(job: UploadProcessingJob) do
      post retry_admin_upload_url(upload),
        headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    upload.reload
    assert upload.pending?
    assert_nil upload.error_message
  end

  test "retrying a failed Audible import starts its durable backup watchdog" do
    upload, media_import = create_failed_audible_import
    old_poll_token = media_import.poll_token

    assert_enqueued_with(
      job: OwnedMediaBackupJob,
      args: ->(args) { args == [ media_import.id, media_import.reload.poll_token ] }
    ) do
      post retry_admin_upload_url(upload)
    end

    assert_no_enqueued_jobs only: UploadProcessingJob
    upload.reload
    media_import.reload
    assert upload.pending?
    assert_nil upload.error_message
    assert media_import.processing?
    assert_nil media_import.completed_at
    assert_nil media_import.error_message
    assert media_import.started_at.present?
    assert_not_equal old_poll_token, media_import.poll_token
  end

  test "an Audible retry remains recoverable when the queue rejects the watchdog" do
    upload, media_import = create_failed_audible_import
    failed_job = Struct.new(:successfully_enqueued?).new(false)

    OwnedMediaBackupJob.stub(:perform_later, failed_job) do
      post retry_admin_upload_url(upload)
    end

    assert_redirected_to admin_uploads_path
    assert_match(/recover this Audible import automatically/, flash[:alert])
    assert upload.reload.pending?
    assert media_import.reload.processing?
    assert media_import.poll_token.present?
  end

  test "an Audible retry remains recoverable when watchdog enqueueing raises" do
    upload, media_import = create_failed_audible_import
    enqueue_failure = ->(*) { raise ActiveJob::EnqueueError, "queue unavailable" }

    OwnedMediaBackupJob.stub(:perform_later, enqueue_failure) do
      assert_nothing_raised { post retry_admin_upload_url(upload) }
    end

    assert_redirected_to admin_uploads_path
    assert_match(/recover this Audible import automatically/, flash[:alert])
    assert upload.reload.pending?
    assert media_import.reload.processing?
    assert media_import.poll_token.present?
  end

  test "retry non-failed upload shows error" do
    upload = Upload.create!(
      user: @admin,
      original_filename: "test.m4b",
      file_path: "/tmp/test.m4b",
      status: :completed
    )

    post retry_admin_upload_url(upload)

    assert_redirected_to admin_uploads_path
    assert_equal "Can only retry failed uploads", flash[:alert]
  end


  private

  def create_failed_audible_import
    connection = OwnedLibraryConnection.create!(enabled: true)
    item = connection.owned_library_items.create!(
      external_id: "B0RETRY#{SecureRandom.hex(2).upcase}",
      title: "Retryable Audible title",
      ownership_type: "purchased"
    )
    upload = Upload.create!(
      user: @admin,
      original_filename: "retryable.m4b",
      file_path: "/tmp/retryable.m4b",
      status: :failed,
      error_message: "Import worker stopped"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: @admin,
      upload: upload,
      status: "failed",
      error_message: "Import worker stopped",
      completed_at: 1.minute.ago,
      poll_token: "stale-poll-token"
    )

    [ upload, media_import ]
  end
end
