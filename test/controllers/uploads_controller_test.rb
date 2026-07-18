# frozen_string_literal: true

require "test_helper"

class UploadsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    @admin = users(:two)
  end

  test "index shows shared uploads for regular users when uploads are disabled" do
    sign_in_as(@user)

    upload = Upload.create!(
      user: @admin,
      original_filename: "admin-book.epub",
      file_path: "/tmp/admin-book.epub",
      status: :pending
    )

    get uploads_url

    assert_response :success
    assert_select "h1", "Uploads"
    assert_select "a[href='#{uploads_path}']", text: "Uploads"
    assert_select "a[href='#{new_upload_path}']", text: "Upload File", count: 0
    assert_select "td", text: upload.original_filename
    assert_select "div", text: @admin.name
  end

  test "index allows admins when uploads are disabled" do
    sign_in_as(@admin)

    get uploads_url

    assert_response :success
    assert_select "a[href='#{uploads_path}']", text: "Uploads"
    assert_select "a[href='#{new_upload_path}']", text: "Upload File"
  end

  test "index shows shared uploads when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)

    own_upload = Upload.create!(
      user: @user,
      original_filename: "own-book.epub",
      file_path: "/tmp/own-book.epub",
      status: :pending
    )
    shared_upload = Upload.create!(
      user: @admin,
      original_filename: "admin-book.epub",
      file_path: "/tmp/admin-book.epub",
      status: :pending
    )

    get uploads_url

    assert_response :success
    assert_select "a[href='#{uploads_path}']", text: "Uploads"
    assert_select "a[href='#{new_upload_path}']", text: "Upload File"
    assert_select "td", text: own_upload.original_filename
    assert_select "td", text: shared_upload.original_filename
    assert_select "div", text: @user.name
    assert_select "div", text: @admin.name
  end

  test "show allows shared uploads when uploads are disabled" do
    sign_in_as(@user)

    upload = Upload.create!(
      user: @admin,
      original_filename: "admin-book.epub",
      file_path: "/tmp/admin-book.epub",
      status: :pending
    )

    get upload_url(upload)

    assert_response :success
    assert_select "h1", "Upload Details"
    assert_select "p", text: /by #{@admin.name}/
  end

  test "create with valid file starts processing for regular users when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post uploads_url,
          params: { file: file },
          headers: { "HTTP_REFERER" => "http://[malformed" }
      end
    end

    assert_redirected_to uploads_path
    assert_equal "File uploaded successfully. Processing started.", flash[:notice]
    assert_equal @user, Upload.order(:created_at).last.user
  end

  test "new redirects regular users when uploads are disabled" do
    sign_in_as(@user)

    get new_upload_url

    assert_redirected_to root_path
    assert_equal "Uploads are not currently enabled.", flash[:alert]
  end

  test "new shows upload form for regular users when uploads are enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)

    get new_upload_url

    assert_response :success
    assert_select "h1", "Upload Book"
    assert_select "form[action='#{uploads_path}']"
    assert_select "input[type='file'][name='files[]'][multiple][accept='.m4a,.m4b,audio/mp4,.mp3,audio/mpeg,.zip,.rar,.epub,.pdf,.mobi,.azw3']"
  end

  test "new shows own request upload context when uploads are enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:pending_request)

    get new_upload_url(request_id: request.id)

    assert_response :success
    assert_select "input[name='request_id'][value='#{request.id}']"
    assert_select "input[type='file'][name='file']"
    assert_select "h2", "Fulfill Request"
  end

  test "new rejects request upload context for another user's request" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:failed_request)
    request.update!(user: @admin)

    get new_upload_url(request_id: request.id)

    assert_redirected_to uploads_path
    assert_equal "You cannot upload files for this request.", flash[:alert]
  end

  test "new redirects away from completed request upload context" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:pending_request)
    request.complete!

    get new_upload_url(request_id: request.id)

    assert_redirected_to request_path(request)
    assert_equal "This request is already completed.", flash[:alert]
  end

  test "create with own request links upload and redirects to request" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:pending_request)
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post uploads_url, params: { file: file, request_id: request.id }
      end
    end

    upload = Upload.order(:created_at).last
    assert_equal request, upload.request
    assert_redirected_to request_path(request)
  end

  test "create accepts multiple files for regular users when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    audiobook = fixture_file_upload("test_audiobook.m4b", "audio/mp4")
    ebook = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_difference "Upload.count", 2 do
      assert_enqueued_jobs 2, only: UploadProcessingJob do
        post uploads_url, params: { files: [ audiobook, ebook ] }
      end
    end

    assert_redirected_to uploads_path
    assert_equal "2 files uploaded successfully. Processing started.", flash[:notice]
  end

  test "create partially accepts multiple files for regular users when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    ebook = fixture_file_upload("test_ebook.epub", "application/epub+zip")
    text = fixture_file_upload("test.txt", "text/plain")

    assert_difference "Upload.count", 1 do
      assert_enqueued_jobs 1, only: UploadProcessingJob do
        post uploads_url, params: { files: [ ebook, text ] }
      end
    end

    assert_redirected_to uploads_path
    assert_equal "1 file uploaded successfully. Processing started.", flash[:notice]
    assert_includes flash[:alert], "test.txt"
    assert_includes flash[:alert], "Unsupported file type"
  end

  test "create from folder skips unsupported files for regular users when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    ebook = fixture_file_upload("test_ebook.epub", "application/epub+zip")
    text = fixture_file_upload("test.txt", "text/plain")

    assert_difference "Upload.count", 1 do
      assert_enqueued_jobs 1, only: UploadProcessingJob do
        post uploads_url, params: { files: [ ebook, text ], upload_mode: "folder" }
      end
    end

    assert_redirected_to uploads_path
    assert_equal "1 file uploaded successfully. Processing started.", flash[:notice]
    assert_nil flash[:alert]
  end

  test "create from folder rejects folders without supported files" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    text = fixture_file_upload("test.txt", "text/plain")

    assert_no_difference "Upload.count" do
      post uploads_url, params: { files: [ text ], upload_mode: "folder" }
    end

    assert_redirected_to new_upload_path
    assert_equal "No supported ebook or audiobook files found in the selected folder", flash[:alert]
  end

  test "create rejects multiple files for request upload context" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:pending_request)
    first_file = fixture_file_upload("test_ebook.epub", "application/epub+zip")
    second_file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_no_difference "Upload.count" do
      post uploads_url, params: { files: [ first_file, second_file ], request_id: request.id }
    end

    assert_redirected_to new_upload_path(request_id: request.id)
    assert_equal "Please upload one file when fulfilling a request", flash[:alert]
  end

  test "create rejects another user's request upload context" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    request = requests(:failed_request)
    request.update!(user: @admin)
    file = fixture_file_upload("test_audiobook.m4b", "audio/mp4")

    assert_no_difference "Upload.count" do
      post uploads_url, params: { file: file, request_id: request.id }
    end

    assert_redirected_to uploads_path
    assert_equal "You cannot upload files for this request.", flash[:alert]
  end

  test "create accepts m4a audiobook uploads for regular users when enabled" do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(@user)
    file = fixture_file_upload("test_audiobook.m4a", "audio/mp4")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        post uploads_url, params: { file: file }
      end
    end

    assert_redirected_to uploads_path
    assert_equal "File uploaded successfully. Processing started.", flash[:notice]
    assert_equal @user, Upload.order(:created_at).last.user
  end

  test "create redirects regular users when uploads are disabled" do
    sign_in_as(@user)
    file = fixture_file_upload("test_ebook.epub", "application/epub+zip")

    assert_no_difference "Upload.count" do
      post uploads_url, params: { file: file }
    end

    assert_redirected_to root_path
    assert_equal "Uploads are not currently enabled.", flash[:alert]
  end
end
