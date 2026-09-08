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


  test "manual matching requires an administrator even for the uploader" do
    upload = create_failed_manual_upload(user: users(:one))
    delete session_url
    sign_in_as(users(:one))

    assert_no_enqueued_jobs do
      assert_no_difference "Book.count" do
        post match_and_retry_admin_upload_url(upload), params: { manual_book: { title: "Replacement" } }
      end
    end

    assert_redirected_to root_path
    assert upload.reload.failed?
    assert_not upload.manual_match?
    get admin_upload_url(upload)
    assert_redirected_to root_path
  end

  test "manual match shows a bounded same-format local search without unavailable books" do
    upload = create_failed_manual_upload
    21.times { |index| Book.create!(title: "Searchable #{index}", book_type: :audiobook) }
    Book.create!(title: "Searchable ebook", book_type: :ebook)
    Book.create!(title: "Searchable acquired", book_type: :audiobook, file_path: "/library/existing")
    Book.create!(title: "Searchable reserved", book_type: :audiobook, acquisition_reservation_token: "other-owner",
      acquisition_reservation_owner_type: "Download", acquisition_reservation_owner_id: 99_001)

    get admin_upload_url(upload), params: { q: "Searchable" }

    assert_response :success
    assert_select "h2", "Correct the match and retry"
    assert_select "input[name='book_id']", count: 20
    assert_select "p", text: /Showing the first 20 matches/
    assert_no_match(/Searchable (ebook|acquired|reserved)/, response.body)

    get admin_upload_url(upload), params: { q: "%" }
    assert_select "input[name='book_id']", count: 0
  end

  test "manual matching uses the selected existing book and queues only once" do
    upload = create_failed_manual_upload
    book = Book.create!(title: "Correct title", book_type: :audiobook)

    assert_no_difference "Book.count" do
      assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
        post match_and_retry_admin_upload_url(upload), params: { book_id: book.id }
      end
    end
    assert_redirected_to admin_upload_path(upload)
    assert upload.reload.pending?
    assert upload.manual_match?
    assert_equal book, upload.book
    assert_nil upload.error_message

    assert_no_enqueued_jobs do
      assert_no_difference "Book.count" do
        post match_and_retry_admin_upload_url(upload), params: { manual_book: { title: "Duplicate" } }
      end
    end
    assert_response :unprocessable_entity
    assert_equal book, upload.reload.book
  end

  test "manual book creation ignores format identity and file-path parameters" do
    upload = create_failed_manual_upload(original_filename: "unrecognized.cbz")

    assert_difference "Book.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
        post match_and_retry_admin_upload_url(upload), params: {
          manual_book: { title: "Corrected comic", author: "Artist", book_type: "ebook",
            file_path: "/library/forged", hardcover_id: "forged", content_kind: "book" },
          request_id: requests(:pending_request).id, file_path: "/tmp/forged"
        }
      end
    end

    assert_redirected_to admin_upload_path(upload)
    assert_equal "comicbook", upload.reload.book.book_type
    assert_equal "graphic", upload.book.content_kind
    assert_equal "Corrected comic", upload.book.title
    assert_nil upload.book.file_path
    assert_nil upload.book.hardcover_id
    assert_nil upload.request_id
    assert_equal "/tmp/manual-upload.m4b", upload.file_path
  end

  test "invalid corrected title keeps entered details on the failure page" do
    upload = create_failed_manual_upload

    assert_no_enqueued_jobs do
      assert_no_difference "Book.count" do
        post match_and_retry_admin_upload_url(upload), params: { manual_book: { title: " ", author: "Entered author" } }
      end
    end

    assert_response :unprocessable_entity
    assert_select "input[name='manual_book[author]'][value='Entered author']"
    assert_select "details[open]"
    assert upload.reload.failed?
    assert_not upload.manual_match?
  end

  test "manual matching rejects unavailable or different-format books" do
    upload = create_failed_manual_upload
    candidates = [
      Book.create!(title: "Different format", book_type: :ebook),
      Book.create!(title: "Acquired", book_type: :audiobook, file_path: "/library/existing"),
      Book.create!(title: "Reserved", book_type: :audiobook, acquisition_reservation_token: "other-owner",
        acquisition_reservation_owner_type: "Download", acquisition_reservation_owner_id: 99_002)
    ]

    candidates.each do |book|
      assert_no_enqueued_jobs do
        post match_and_retry_admin_upload_url(upload), params: { book_id: book.id }
      end
      assert_response :unprocessable_entity
      assert upload.reload.failed?
      assert_nil upload.book_id
      assert_not upload.manual_match?
    end
    assert_equal "/library/existing", candidates[1].reload.file_path
    assert_equal "other-owner", candidates[2].reload.acquisition_reservation_token
  end

  test "manual matching cannot reassign request uploads Audible imports or reserved destinations" do
    audible_upload, = create_failed_audible_import
    uploads = [
      create_failed_manual_upload(request: requests(:pending_request)),
      audible_upload,
      create_failed_manual_upload(destination_path: "/library/reserved")
    ]

    uploads.each do |upload|
      get admin_upload_url(upload)
      assert_select "h2", text: "Correct the match and retry", count: 0
      assert_no_enqueued_jobs do
        assert_no_difference "Book.count" do
          post match_and_retry_admin_upload_url(upload), params: { manual_book: { title: "Replacement" } }
        end
      end
      assert_response :unprocessable_entity
      assert upload.reload.failed?
      assert_not upload.manual_match?
    end
  end

  test "rejected or raised enqueue preserves the manual choice for ordinary Retry" do
    [ false, ->(*) { raise ActiveJob::EnqueueError, "queue unavailable" } ].each do |enqueue_result|
      upload = create_failed_manual_upload
      UploadProcessingJob.stub(:perform_later, enqueue_result) do
        post match_and_retry_admin_upload_url(upload), params: { manual_book: { title: "Saved choice" } }
      end
      assert_redirected_to admin_upload_path(upload)
      assert upload.reload.failed?
      assert upload.manual_match?
      assert_equal "Saved choice", upload.book.title
      assert_match(/manual match was saved/i, flash[:alert])
      selected_id = upload.book_id

      assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
        post retry_admin_upload_url(upload)
      end
      assert upload.reload.pending?
      assert_equal selected_id, upload.book_id
      assert upload.manual_match?
    end
  end

  private

  def create_failed_manual_upload(**attributes)
    Upload.create!({
      user: @admin, original_filename: "unrecognized.m4b", file_path: "/tmp/manual-upload.m4b",
      status: :failed, error_message: "Automatic match failed", parsed_title: "Unrecognized"
    }.merge(attributes))
  end

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
