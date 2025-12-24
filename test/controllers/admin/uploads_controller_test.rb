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
    get admin_uploads_url
    assert_response :success
  end

  test "new shows upload form" do
    get new_admin_upload_url
    assert_response :success
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
