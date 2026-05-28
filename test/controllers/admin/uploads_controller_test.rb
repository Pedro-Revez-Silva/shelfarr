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
        post admin_uploads_url, params: { file: file }
      end
    end

    assert_redirected_to admin_uploads_path
    assert_equal "File uploaded successfully. Processing started.", flash[:notice]
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
      delete admin_upload_url(upload)
    end

    assert_redirected_to admin_uploads_path
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
      post retry_admin_upload_url(upload)
    end

    upload.reload
    assert upload.pending?
    assert_nil upload.error_message
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
end
