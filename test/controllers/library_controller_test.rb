# frozen_string_literal: true

require "test_helper"

class LibraryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @admin = users(:two)
    @acquired_audiobook = books(:audiobook_acquired)
    sign_in_as(@user)
  end

  test "index requires authentication" do
    sign_out
    get library_index_path
    assert_response :redirect
  end

  test "index shows acquired books" do
    get library_index_path
    assert_response :success
    assert_select "h1", "Library"
    assert_select "a[href='#{library_path(@acquired_audiobook)}']"
  end

  test "index filters by audiobook type" do
    get library_index_path(type: "audiobook")
    assert_response :success
    assert_select "a[href='#{library_path(@acquired_audiobook)}']"
  end

  test "index filters by ebook type" do
    ebook = Book.create!(
      title: "Acquired Ebook",
      author: "Test Author",
      book_type: :ebook,
      file_path: "/ebooks/Test Author/Acquired Ebook"
    )

    get library_index_path(type: "ebook")
    assert_response :success
    assert_select "a[href='#{library_path(ebook)}']"
  end

  test "index shows empty state when no books" do
    Book.where.not(file_path: nil).update_all(file_path: nil)

    get library_index_path
    assert_response :success
    assert_select "h3", "Your library is empty"
  end

  test "show displays book details" do
    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "h1", @acquired_audiobook.title
  end

  test "show returns 404 for non-acquired book" do
    pending_book = books(:ebook_pending)

    get library_path(pending_book)
    assert_response :not_found
  end

  test "show displays download button when user has request" do
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :completed
    )

    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "a[href='#{download_request_path(request)}']", text: /Download/
  end

  test "show does not display download button when user has no request" do
    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "a[href*='download']", false
  end

  test "show displays file path for admin" do
    sign_out
    sign_in_as(@admin)

    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "code", @acquired_audiobook.file_path
  end

  test "show does not display file path for regular user" do
    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "code", false
  end

  test "retry post processing requires admin" do
    post retry_post_processing_library_path(@acquired_audiobook)

    assert_redirected_to library_index_path
    assert_equal "Only admins can retry post-processing", flash[:alert]
  end

  test "retry post processing redirects when no retryable download exists" do
    sign_out
    sign_in_as(@admin)

    post retry_post_processing_library_path(@acquired_audiobook)

    assert_redirected_to library_path(@acquired_audiobook)
    assert_equal "No retryable post-processing found for this book", flash[:alert]
  end

  test "retry post processing clears attention and queues job" do
    sign_out
    sign_in_as(@admin)
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :processing,
      attention_needed: true,
      issue_description: "Post-processing failed"
    )
    download = request.downloads.create!(
      name: "Finished",
      status: :completed,
      post_processing_job_id: "failed-job-id"
    )

    retry_args = ->(args) { args == [ download.id, 0, "failed-job-id" ] }
    assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      post retry_post_processing_library_path(@acquired_audiobook)
    end

    assert_redirected_to library_path(@acquired_audiobook)
    assert_equal "Post-processing has been queued for retry.", flash[:notice]
    assert_not request.reload.attention_needed?
    assert_nil request.issue_description
    assert_equal "failed-job-id", download.reload.post_processing_job_id
  end

  test "retry post processing retains attention when enqueue fails" do
    sign_out
    sign_in_as(@admin)
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :processing,
      attention_needed: true,
      issue_description: "Post-processing failed"
    )
    request.downloads.create!(name: "Finished", status: :completed)
    failed_job = PostProcessingJob.new(0)

    PostProcessingJob.stub(:new, failed_job) do
      failed_job.stub(:enqueue, false) do
        post retry_post_processing_library_path(@acquired_audiobook)
      end
    end

    assert_redirected_to library_path(@acquired_audiobook)
    assert_match(/Failed to queue post-processing retry/, flash[:alert])
    assert request.reload.attention_needed?
    assert_equal "Post-processing failed", request.issue_description
  end

  test "destroy requires admin" do
    delete library_path(@acquired_audiobook)

    assert_redirected_to library_index_path
    assert_equal "Only admins can delete books from the library", flash[:alert]
    assert Book.exists?(@acquired_audiobook.id)
  end

  test "destroy removes book and associated requests" do
    sign_out
    sign_in_as(@admin)
    Request.create!(book: @acquired_audiobook, user: @user, status: :completed)

    assert_difference -> { Book.count }, -1 do
      delete library_path(@acquired_audiobook)
    end

    assert_redirected_to library_index_path
    assert_equal "\"#{@acquired_audiobook.title}\" has been removed from the library", flash[:notice]
    assert_empty Request.where(book_id: @acquired_audiobook.id)
  end

  test "destroy deletes file inside configured output directory" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      file_path = File.join(dir, "book.epub")
      File.write(file_path, "book")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Temporary Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: file_path
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path
      assert_not File.exist?(file_path)
      assert_not Book.exists?(book.id)
    end
  end

  test "destroy does not delete file outside configured output directories" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      file_path = File.join(dir, "outside.epub")
      File.write(file_path, "book")
      SettingsService.set(:ebook_output_path, File.join(dir, "allowed"))
      book = Book.create!(
        title: "Outside Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: file_path
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path
      assert File.exist?(file_path)
    end
  end

  test "destroy does not delete the output root when a flat-imported book points at it" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      other_book_file = File.join(dir, "other-book.epub")
      File.write(other_book_file, "book")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Flat Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: dir
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path
      assert File.directory?(dir)
      assert File.exist?(other_book_file)
      assert_not Book.exists?(book.id)
    end
  end
end
