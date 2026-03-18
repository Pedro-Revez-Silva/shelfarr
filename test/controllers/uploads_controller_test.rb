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
        post uploads_url, params: { file: file }
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
    assert_select "input[type='file'][name='file']"
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
