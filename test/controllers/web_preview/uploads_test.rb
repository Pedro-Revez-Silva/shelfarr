# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::UploadsTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  setup do
    @member = users(:one)
    @admin = users(:two)
    @other = User.create!(name: "Other Member", username: "other_member_uploads", password: "Password123!")
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin, @other ].map { |user| user.id.to_s }.join(",")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    Upload.where.not(file_path: nil).pluck(:file_path).each { |path| FileUtils.rm_f(path) if path.start_with?(Rails.root.join("tmp/uploads").to_s) }
  end

  def member_upload(**attributes)
    Upload.create!({ user: @member, original_filename: "member-book.epub", file_path: "/tmp/member-book.epub", status: :pending }.merge(attributes))
  end

  def failed_manual_upload(**attributes)
    Upload.create!({ user: @admin, original_filename: "unrecognized.m4b", file_path: "/tmp/manual-upload.m4b",
      status: :failed, error_message: "Automatic match failed", parsed_title: "Unrecognized" }.merge(attributes))
  end

  def list(user)
    sign_in_as(user)
    preview_get web_preview_api_uploads_path, user: user
    response.parsed_body
  end

  def upload_files(params, user:)
    sign_in_as(user)
    post web_preview_api_uploads_path, params: params, headers: account_headers(user)
  end

  def admin_write(verb, path, params = {}, user: @admin)
    sign_in_as(user)
    send(verb, path, params: params, headers: account_headers(user), as: :json)
  end

  def item(body, upload)
    body.fetch("items").find { |entry| entry.fetch("id") == upload.id.to_s }
  end

  test "the list answers privately and refuses outsiders" do
    upload = member_upload

    get web_preview_api_uploads_path, headers: account_headers(@member)
    assert_response :unauthorized
    assert_equal "signed_out", response.parsed_body.fetch("error")

    sign_in_as(@member)
    preview_get web_preview_api_uploads_path, user: @admin
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")

    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    preview_get web_preview_api_uploads_path, user: @member
    assert_response :not_found

    ENV[WebPreview::Access::VARIABLE] = @member.id.to_s
    preview_get web_preview_api_uploads_path, user: @member
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal [ upload.id.to_s ], response.parsed_body.fetch("items").map { |entry| entry.fetch("id") }
  end

  test "members see the shared uploads with safe fields and no administration" do
    SettingsService.set(:allow_user_uploads, false)
    own = member_upload(status: :failed, error_message: "Errno::ENOENT /srv/library/secret path", parsed_title: "Dune", parsed_author: "Frank Herbert", match_confidence: 82, file_size: 1234)
    request = requests(:failed_request)
    other_request = Request.create!(user: @other, book: books(:ebook_pending), status: :pending)
    shared = Upload.create!(user: @other, request: other_request, original_filename: "other.epub", file_path: "/tmp/other.epub", status: :completed)
    with_request = member_upload(request: request, original_filename: "fulfil.m4b")

    body = list(@member)

    assert_equal false, body.fetch("can_upload")
    assert_equal Upload::EBOOK_EXTENSIONS, body.dig("formats", "ebook")
    assert_equal UploadCreator::MAX_UPLOAD_BYTES, body.fetch("max_bytes")
    assert_equal({
      "id" => own.id.to_s, "filename" => "member-book.epub", "size" => 1234, "book_type" => nil, "status" => "failed",
      "created_at" => own.created_at.iso8601(3), "processed_at" => nil,
      "parsed" => { "title" => "Dune", "author" => "Frank Herbert", "confidence" => 82 },
      "book" => nil, "request_id" => nil, "uploaded_by_you" => true,
      "failure" => WebPreview::UploadJson::MEMBER_FAILURE
    }, item(body, own))
    assert_equal false, item(body, shared).fetch("uploaded_by_you")
    assert_nil item(body, shared).fetch("request_id")
    assert_equal request.id.to_s, item(body, with_request).fetch("request_id")
    refute_includes response.body, "Other Member"
    refute_includes response.body, "/srv/library"
    refute item(body, own).key?("actions")
  end

  test "administrators see who uploaded, the redacted failure and the classic actions" do
    SettingsService.set(:audiobookshelf_api_key, "abs-secret-key-1234")
    upload = failed_manual_upload(error_message: "Library rejected key abs-secret-key-1234")
    reserved = failed_manual_upload(original_filename: "reserved.m4b", destination_path: "/library/reserved.m4b")
    done = member_upload(status: :completed, book: books(:audiobook_acquired))

    body = list(@admin)

    assert_equal true, body.fetch("can_upload")
    entry = item(body, upload)
    assert_equal "Library rejected key [hidden]", entry.fetch("failure")
    assert_equal @admin.name, entry.fetch("uploaded_by")
    assert_equal({ "retry" => true, "match" => true, "remove" => true }, entry.fetch("actions"))
    assert_equal false, entry.fetch("reserved_file")
    assert_equal({ "retry" => true, "match" => false, "remove" => true }, item(body, reserved).fetch("actions"))
    assert_equal true, item(body, reserved).fetch("reserved_file")
    assert_equal({ "retry" => false, "match" => false, "remove" => true }, item(body, done).fetch("actions"))
    book = books(:audiobook_acquired)
    assert_equal({ "title" => book.title, "author" => book.author, "acquired" => true, "publication_id" => book.id.to_s }, item(body, done).fetch("book"))
  end

  test "the list pages through every upload" do
    55.times { |index| member_upload(original_filename: "book-#{index}.epub") }

    first = list(@member)
    assert_equal [ 1, 50, 55, 2 ], first.values_at("page", "per_page", "total", "total_pages")
    assert_equal 50, first.fetch("items").size
    preview_get web_preview_api_uploads_path(page: "2"), user: @member
    assert_equal 5, response.parsed_body.fetch("items").size
    preview_get web_preview_api_uploads_path(page: "99"), user: @member
    assert_equal 2, response.parsed_body.fetch("page")
  end

  test "a member's own open request is offered as upload context and another member's is not found" do
    SettingsService.set(:allow_user_uploads, true)
    request = requests(:pending_request)
    sign_in_as(@member)

    preview_get web_preview_api_upload_request_context_path(request_id: request.id), user: @member
    assert_response :success
    assert_equal({ "id" => request.id.to_s, "title" => request.book.title, "author" => request.book.author, "book_type" => request.book.book_type, "open" => true, "message" => nil },
      response.parsed_body.fetch("request"))

    sign_in_as(@other)
    preview_get web_preview_api_upload_request_context_path(request_id: request.id), user: @other
    assert_response :not_found

    sign_in_as(@admin)
    preview_get web_preview_api_upload_request_context_path(request_id: request.id), user: @admin
    assert_response :success

    request.complete!
    preview_get web_preview_api_upload_request_context_path(request_id: request.id), user: @admin
    assert_equal [ false, "This request is already completed." ], response.parsed_body.fetch("request").values_at("open", "message")
  end

  test "members cannot use the upload form while uploads are off" do
    SettingsService.set(:allow_user_uploads, false)
    sign_in_as(@member)

    preview_get web_preview_api_upload_request_context_path(request_id: requests(:pending_request).id), user: @member
    assert_response :forbidden
    assert_equal [ "uploads_disabled", "Uploads are not currently enabled." ], response.parsed_body.values_at("error", "message")

    assert_no_difference "Upload.count" do
      upload_files({ file: fixture_file_upload("test_ebook.epub", "application/epub+zip") }, user: @member)
    end
    assert_response :forbidden
  end

  test "an upload goes through the classic pipeline and starts processing" do
    SettingsService.set(:allow_user_uploads, true)

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        upload_files({ file: fixture_file_upload("test_ebook.epub", "application/epub+zip") }, user: @member)
      end
    end

    assert_response :created
    upload = Upload.order(:id).last
    assert_equal({ "account" => @member.id.to_s, "notice" => "File uploaded successfully. Processing started.", "uploads" => [ upload.id.to_s ] }, response.parsed_body)
    assert_equal @member, upload.user
    assert upload.file_path.start_with?(Rails.root.join("tmp/uploads").to_s)
  end

  test "several files and folders keep the classic rules" do
    files = [ fixture_file_upload("test_audiobook.m4b", "audio/mp4"), fixture_file_upload("test.txt", "text/plain") ]

    assert_difference "Upload.count", 1 do
      upload_files({ files: files, upload_mode: "folder" }, user: @admin)
    end
    assert_response :created
    assert_equal "1 file uploaded successfully. Processing started.", response.parsed_body.fetch("notice")

    assert_no_difference "Upload.count" do
      upload_files({ files: [ fixture_file_upload("test.txt", "text/plain") ], upload_mode: "folder" }, user: @admin)
    end
    assert_response :unprocessable_entity
    assert_equal [ "upload_rejected", "No supported ebook or audiobook files found in the selected folder" ], response.parsed_body.values_at("error", "message")

    upload_files({ files: [ fixture_file_upload("test_ebook.epub"), fixture_file_upload("test.txt", "text/plain") ] }, user: @admin)
    assert_response :created
    assert_match(/1 file failed to upload: test.txt: Unsupported file type/, response.parsed_body.fetch("alert"))

    upload_files({ file: fixture_file_upload("test.txt", "text/plain") }, user: @admin)
    assert_response :unprocessable_entity
    assert_equal "Unsupported file type. Supported: #{Upload::SUPPORTED_EXTENSIONS.join(', ')}", response.parsed_body.fetch("message")

    upload_files({}, user: @admin)
    assert_response :unprocessable_entity
    assert_equal "Please select a file to upload", response.parsed_body.fetch("message")

    upload_files({ file: "not-a-file" }, user: @admin)
    assert_response :bad_request
  end

  test "a request upload keeps ownership, format and single-file rules" do
    SettingsService.set(:allow_user_uploads, true)
    request = requests(:pending_request)

    assert_no_difference "Upload.count" do
      upload_files({ request_id: request.id.to_s, file: fixture_file_upload("test_ebook.epub") }, user: @other)
    end
    assert_response :not_found

    upload_files({ request_id: request.id.to_s, files: [ fixture_file_upload("test_ebook.epub"), fixture_file_upload("test_ebook.epub") ] }, user: @member)
    assert_response :unprocessable_entity
    assert_equal "Please upload one file when fulfilling a request", response.parsed_body.fetch("message")

    upload_files({ request_id: request.id.to_s, file: fixture_file_upload("test_audiobook.m4b", "audio/mp4") }, user: @member)
    assert_response :unprocessable_entity
    assert_equal "Uploaded file type does not match this ebook request", response.parsed_body.fetch("message")

    assert_difference "Upload.count", 1 do
      upload_files({ request_id: request.id.to_s, file: fixture_file_upload("test_ebook.epub") }, user: @member)
    end
    assert_response :created
    assert_equal request.id.to_s, response.parsed_body.fetch("request_id")
    assert_equal request, Upload.order(:id).last.request

    request.complete!
    assert_no_difference "Upload.count" do
      upload_files({ request_id: request.id.to_s, file: fixture_file_upload("test_ebook.epub") }, user: @member)
    end
    assert_response :conflict
    assert_equal [ "upload_closed", "This request is already completed." ], response.parsed_body.values_at("error", "message")

    upload_files({ request_id: "abc", file: fixture_file_upload("test_ebook.epub") }, user: @admin)
    assert_response :not_found
  end

  test "every write needs the page's CSRF token" do
    upload = failed_manual_upload
    with_forgery_protection do
      sign_in_as(@admin)
      assert_no_difference "Upload.count" do
        post web_preview_api_uploads_path, params: { file: fixture_file_upload("test_ebook.epub") }, headers: account_headers(@admin)
      end
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      [ [ :post, web_preview_api_admin_upload_retry_path(upload) ], [ :post, web_preview_api_admin_upload_match_path(upload) ], [ :delete, web_preview_api_admin_upload_path(upload) ] ].each do |verb, path|
        send(verb, path, headers: account_headers(@admin), as: :json)
        assert_equal "invalid_csrf", response.parsed_body.fetch("error"), path
      end
      assert upload.reload.failed?

      token = csrf_token
      post web_preview_api_uploads_path, params: { file: fixture_file_upload("test_ebook.epub") }, headers: account_headers(@admin).merge("X-CSRF-Token" => token)
      assert_response :created
    end
  end

  test "members cannot reach upload administration" do
    upload = failed_manual_upload(user: @member)
    [ [ :post, web_preview_api_admin_upload_retry_path(upload) ], [ :get, web_preview_api_admin_upload_matches_path(upload) ],
      [ :post, web_preview_api_admin_upload_match_path(upload) ], [ :delete, web_preview_api_admin_upload_path(upload) ] ].each do |verb, path|
      admin_write(verb, path, {}, user: @member)
      assert_response :not_found, path
    end
    assert upload.reload.failed?
  end

  test "retry follows the classic rules" do
    upload = failed_manual_upload

    assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
      admin_write(:post, web_preview_api_admin_upload_retry_path(upload))
    end
    assert_response :success
    assert_equal({ "tone" => "success", "message" => "Upload queued for retry." }, response.parsed_body.fetch("outcome"))
    assert upload.reload.pending?

    admin_write(:post, web_preview_api_admin_upload_retry_path(upload))
    assert_response :conflict
    assert_equal [ "upload_refused", "Can only retry failed uploads" ], response.parsed_body.values_at("error", "message")

    upload.update!(status: :failed)
    UploadProcessingJob.stub(:perform_later, false) do
      admin_write(:post, web_preview_api_admin_upload_retry_path(upload))
    end
    assert_response :success
    assert_equal({ "tone" => "error", "message" => "Upload retry could not be queued. Try again." }, response.parsed_body.fetch("outcome"))
    assert_equal "Shelfarr could not queue the upload retry", upload.reload.error_message
  end

  test "removal deletes safe uploads and keeps reserved ones" do
    upload = failed_manual_upload
    assert_difference "Upload.count", -1 do
      admin_write(:delete, web_preview_api_admin_upload_path(upload))
    end
    assert_equal({ "tone" => "success", "message" => "Upload deleted." }, response.parsed_body.fetch("outcome"))

    reserved = failed_manual_upload(destination_path: "/library/reserved.m4b")
    assert_no_difference "Upload.count" do
      admin_write(:delete, web_preview_api_admin_upload_path(reserved))
    end
    assert_response :conflict
    assert_equal UploadAdministration::RESERVED_FILE_MESSAGE, response.parsed_body.fetch("message")

    admin_write(:delete, web_preview_api_admin_upload_path(id: "x1"))
    assert_response :not_found
  end

  test "manual matching lists same-format free books and saves the choice" do
    upload = failed_manual_upload
    free = Book.create!(title: "Unrecognized Saga", author: "A. Writer", book_type: :audiobook)
    Book.create!(title: "Unrecognized Ebook", book_type: :ebook)
    Book.create!(title: "Unrecognized Owned", book_type: :audiobook, file_path: "/library/owned.m4b")

    admin_write(:get, web_preview_api_admin_upload_matches_path(upload))
    assert_response :success
    assert_equal({ "account" => @admin.id.to_s, "book_type" => "audiobook", "query" => "Unrecognized", "page" => 1, "more" => false,
      "books" => [ { "id" => free.id.to_s, "title" => "Unrecognized Saga", "author" => "A. Writer" } ],
      "manual_book" => { "title" => "Unrecognized", "author" => "" } }, response.parsed_body)

    admin_write(:get, web_preview_api_admin_upload_matches_path(upload, q: "zzz"))
    assert_equal [], response.parsed_body.fetch("books")

    assert_enqueued_with(job: UploadProcessingJob, args: [ upload.id ]) do
      admin_write(:post, web_preview_api_admin_upload_match_path(upload), { book_id: free.id.to_s })
    end
    assert_equal({ "tone" => "success", "message" => "Manual match saved. Upload queued for retry." }, response.parsed_body.fetch("outcome"))
    assert_equal free, upload.reload.book
    assert upload.manual_match?
    assert_equal 1, ActivityLog.for_action("upload.manually_matched").count

    admin_write(:get, web_preview_api_admin_upload_matches_path(upload))
    assert_response :conflict
    assert_equal "match_unavailable", response.parsed_body.fetch("error")
  end

  test "manual matching prefills the full book details and searches every book for an empty query" do
    title = "T" * 260
    author = "A" * 240
    upload = failed_manual_upload(book: Book.create!(title: title, author: author, book_type: :audiobook))
    other = Book.create!(title: "Different saga", book_type: :audiobook)

    admin_write(:get, web_preview_api_admin_upload_matches_path(upload))
    assert_equal({ "title" => title, "author" => author }, response.parsed_body.fetch("manual_book"))
    refute_includes response.parsed_body.fetch("books").map { |book| book.fetch("id") }, other.id.to_s

    admin_write(:get, web_preview_api_admin_upload_matches_path(upload, q: ""))
    assert_includes response.parsed_body.fetch("books").map { |book| book.fetch("id") }, other.id.to_s
  end

  test "manual matching creates a corrected book and reports invalid choices" do
    upload = failed_manual_upload

    admin_write(:post, web_preview_api_admin_upload_match_path(upload), { manual_book: { title: " " } })
    assert_response :unprocessable_entity
    assert_equal "match_rejected", response.parsed_body.fetch("error")
    assert upload.reload.failed?

    ebook = Book.create!(title: "Wrong format", book_type: :ebook)
    admin_write(:post, web_preview_api_admin_upload_match_path(upload), { book_id: ebook.id.to_s })
    assert_response :unprocessable_entity
    assert_equal "Choose a book with the same format as this upload.", response.parsed_body.fetch("message")

    admin_write(:post, web_preview_api_admin_upload_match_path(upload), { book_id: "999999" })
    assert_response :conflict
    assert_equal "That book is no longer available. Choose another book.", response.parsed_body.fetch("message")

    admin_write(:post, web_preview_api_admin_upload_match_path(upload), { book_id: [ "1" ] })
    assert_response :bad_request

    assert_difference "Book.count", 1 do
      admin_write(:post, web_preview_api_admin_upload_match_path(upload), { manual_book: { title: "Corrected", author: "Writer" } })
    end
    assert_response :success
    assert_equal [ "Corrected", "Writer", "audiobook" ], upload.reload.book.attributes.values_at("title", "author", "book_type")
  end
end
