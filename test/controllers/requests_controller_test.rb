# frozen_string_literal: true

require "test_helper"

class RequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @admin = users(:two)
    @pending_request = requests(:pending_request)
    @failed_request = requests(:failed_request)
    sign_in_as(@user)
  end

  test "index requires authentication" do
    sign_out
    get requests_path
    assert_response :redirect
  end

  test "index shows user's requests" do
    get requests_path
    assert_response :success
    assert_select "h1", "My Requests"
  end

  test "admin sees all requests" do
    sign_out
    sign_in_as(@admin)
    get requests_path
    assert_response :success
    assert_select "h1", "All Requests"
  end

  test "index filters by status" do
    sign_out
    sign_in_as(@admin)

    # Create requests with different statuses
    completed_request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :completed
    )

    get requests_path(status: "completed")
    assert_response :success

    # Should only show completed requests
    assert_select "h3", completed_request.book.title
  end

  test "index filters by active status excluding attention needed" do
    sign_out
    sign_in_as(@admin)

    # Create an active request without attention needed
    active_request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :pending,
      attention_needed: false
    )

    # Create an active request with attention needed
    attention_request = Request.create!(
      book: books(:ebook_pending),
      user: @user,
      status: :searching,
      attention_needed: true
    )

    get requests_path(status: "active")
    assert_response :success

    # Active filter should exclude requests needing attention
    assert_select "h3", active_request.book.title
    assert_select "h3", text: attention_request.book.title, count: 0
  end

  test "index filters by attention needed" do
    sign_out
    sign_in_as(@admin)

    # Create a request needing attention
    attention_request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :downloading,
      attention_needed: true,
      issue_description: "Download failed"
    )

    get requests_path(attention: "true")
    assert_response :success

    # Should show requests needing attention
    assert_select "h3", attention_request.book.title
  end

  test "index shows attention count and active count" do
    sign_out
    sign_in_as(@admin)

    get requests_path
    assert_response :success

    # Should have filter tabs rendered
    assert_select "a", text: /Need Attention/
    assert_select "a", text: /Active/
  end

  test "show displays request details" do
    get request_path(@pending_request)
    assert_response :success
    assert_select "h1", @pending_request.book.title
  end

  test "user cannot view another user's request" do
    other_user = users(:two)
    other_request = Request.create!(
      book: books(:audiobook_acquired),
      user: other_user,
      status: :pending
    )

    get request_path(other_request)
    assert_response :not_found
  end

  test "admin can view any request" do
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)
    assert_response :success
  end

  test "new requires work_id and title" do
    get new_request_path
    assert_redirected_to search_path
    assert_equal "Missing book information", flash[:alert]
  end

  test "new shows request form with book info" do
    get new_request_path, params: {
      work_id: "OL12345W",
      title: "Test Book",
      author: "Test Author"
    }
    assert_response :success
    assert_select "h2", "Test Book"
  end

  test "create creates book and request" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      post requests_path, params: {
        work_id: "OL_NEW_123W",
        title: "New Book",
        author: "New Author",
        book_type: "audiobook"
      }
    end

    book = Book.last
    assert_equal "New Book", book.title
    assert_equal "audiobook", book.book_type
    assert_equal @user, book.requests.last.user
    assert_redirected_to request_path(Request.last)
  end

  test "create reuses existing book" do
    existing_book = Book.create!(
      title: "Existing",
      book_type: :ebook,
      open_library_work_id: "OL_EXISTING_W"
    )

    assert_no_difference "Book.count" do
      assert_difference "Request.count", 1 do
        post requests_path, params: {
          work_id: "OL_EXISTING_W",
          title: "Existing",
          book_type: "ebook"
        }
      end
    end
  end

  test "create blocks duplicate for acquired book" do
    book = Book.create!(
      title: "Acquired",
      book_type: :audiobook,
      open_library_work_id: "OL_ACQUIRED_W",
      file_path: "/audiobooks/Author/Acquired"
    )

    assert_no_difference [ "Book.count", "Request.count" ] do
      post requests_path, params: {
        work_id: "OL_ACQUIRED_W",
        title: "Acquired",
        book_type: "audiobook"
      }
    end

    assert_redirected_to search_path
    assert_includes flash[:alert], "already in your library"
  end

  test "destroy cancels pending request" do
    assert_difference "Request.count", -1 do
      delete request_path(@pending_request)
    end
    assert_redirected_to requests_path
    assert_equal "Request cancelled", flash[:notice]
  end

  test "destroy cancels failed request" do
    assert_difference "Request.count", -1 do
      delete request_path(@failed_request)
    end
    assert_redirected_to requests_path
  end

  test "destroy cleans up orphaned book without requests" do
    book = Book.create!(
      title: "Orphan Book",
      book_type: :ebook,
      open_library_work_id: "OL_ORPHAN_W"
    )
    request = Request.create!(book: book, user: @user, status: :pending)

    assert_difference [ "Request.count", "Book.count" ], -1 do
      delete request_path(request)
    end
  end

  test "destroy does not clean up book with file" do
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :pending)

    assert_difference "Request.count", -1 do
      assert_no_difference "Book.count" do
        delete request_path(request)
      end
    end
  end

  test "destroy rejects non-cancellable status" do
    @pending_request.update!(status: :downloading)

    assert_no_difference "Request.count" do
      delete request_path(@pending_request)
    end

    assert_redirected_to request_path(@pending_request)
    assert_includes flash[:alert], "Cannot cancel"
  end

  test "user cannot cancel another user's request" do
    other_user = users(:two)
    other_request = Request.create!(
      book: books(:ebook_pending),
      user: other_user,
      status: :pending
    )

    delete request_path(other_request)
    assert_response :not_found
  end

  # Retry tests
  test "retry requires admin" do
    # Regular user should be rejected
    post retry_request_path(@failed_request)

    assert_response :redirect
    assert_equal "You don't have permission to retry requests", flash[:alert]
  end

  test "admin can retry a request" do
    sign_out
    sign_in_as(@admin)

    @failed_request.update!(attention_needed: true, issue_description: "Test issue")

    post retry_request_path(@failed_request)

    @failed_request.reload
    assert @failed_request.pending?
    assert_not @failed_request.attention_needed?
    assert_nil @failed_request.issue_description
    assert_equal "Request has been queued for retry.", flash[:notice]
  end

  test "retry redirects back to referring page" do
    sign_out
    sign_in_as(@admin)

    # Set referer header to simulate coming from requests index
    post retry_request_path(@failed_request), headers: { "HTTP_REFERER" => requests_path }

    assert_redirected_to requests_path
  end

  # Download tests
  test "download requires authentication" do
    sign_out
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :redirect
  end

  test "download redirects if book not acquired" do
    request = @pending_request
    assert_not request.book.acquired?

    get download_request_path(request)
    assert_redirected_to library_index_path
    assert_equal "This book is not available for download", flash[:alert]
  end

  test "download redirects if file not found" do
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_redirected_to request_path(request)
    assert_equal "File not found on server", flash[:alert]
  end

  test "download sends single file" do
    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test_audiobook.m4b")
    File.write(temp_file, "test audio content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Test Download",
      author: "Test Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :success
    assert_equal "audio/mp4", response.content_type
    assert_match /attachment/, response.headers["Content-Disposition"]
    assert_match /test_audiobook\.m4b/, response.headers["Content-Disposition"]
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "download sends zipped directory" do
    temp_dir = Dir.mktmpdir
    book_dir = File.join(temp_dir, "Test Author", "Test Book")
    FileUtils.mkdir_p(book_dir)
    File.write(File.join(book_dir, "part1.m4b"), "audio part 1")
    File.write(File.join(book_dir, "part2.m4b"), "audio part 2")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Test Book",
      author: "Test Author",
      book_type: :audiobook,
      file_path: book_dir
    )
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :success
    assert_equal "application/zip", response.content_type
    assert_match /attachment/, response.headers["Content-Disposition"]
    assert_match /Test Author - Test Book\.zip/, response.headers["Content-Disposition"]
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "user can download another user's request when book is acquired" do
    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test.m4b")
    File.write(temp_file, "content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Other User Book",
      author: "Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    other_request = Request.create!(book: book, user: @admin, status: :completed)

    # Users can download any acquired book, regardless of who requested it
    get download_request_path(other_request)
    assert_response :success
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "admin can download any user's request" do
    sign_out
    sign_in_as(@admin)

    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test.m4b")
    File.write(temp_file, "content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "User Book",
      author: "Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    user_request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(user_request)
    assert_response :success
  ensure
    FileUtils.rm_rf(temp_dir)
  end
end
