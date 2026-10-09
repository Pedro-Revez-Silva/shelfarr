# frozen_string_literal: true

require "test_helper"

class CompletedRequestHistoryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @root = Dir.mktmpdir("completed-history")
    @path = File.join(@root, "Completed.epub")
    File.binwrite(@path, "library bytes")
    SettingsService.set(:ebook_output_path, @root)
    @book = Book.create!(title: "Completed", book_type: :ebook,
      open_library_work_id: "OL_HISTORY_RE_REQUEST", file_path: @path)
    @history_request = Request.create!(book: @book, user: @user, status: :completed, language: "en")
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "completed history can be deleted while library bytes remain downloadable" do
    assert_difference "Request.count", -1 do
      assert_no_difference "Book.count" do
        delete request_path(@history_request)
      end
    end
    assert_redirected_to requests_path
    assert_equal "library bytes", File.binread(@path)
    get "/library/#{@book.id}/download"
    assert_response :success
    assert_equal "library bytes", response.body
  end

  test "completed details expose deletion and explain how to request again" do
    get request_path(@history_request)
    assert_response :success
    assert_select "button", text: "Delete Request", minimum: 1
    assert_select "a[href='#{library_path(@book)}']", text: /Library/
    assert_select "input[name='remove_torrent']", count: 0
  end

  test "completed admin list exposes deletion" do
    sign_out
    sign_in_as(users(:two))
    get requests_path(status: "completed")
    assert_response :success
    assert_select "form[action='#{request_path(@history_request)}'] button", text: "Delete"
  end

  test "regular user cannot delete another user's completed history" do
    @history_request.update!(user: users(:two))
    assert_no_difference "Request.count" do
      delete request_path(@history_request)
    end
    assert_response :not_found
  end

  test "completed history with active download remains recoverable" do
    @history_request.downloads.create!(name: "Active", status: :downloading)
    assert_no_difference [ "Request.count", "Download.count", "Book.count" ] do
      delete request_path(@history_request)
    end
    assert_redirected_to request_path(@history_request)
    assert_includes flash[:alert], "active download"
  end

  test "completed history with post-processing recovery remains recoverable" do
    @history_request.downloads.create!(name: "Imported", status: :completed,
      post_processing_cleanup_state: "{}")
    assert_no_difference [ "Request.count", "Download.count", "Book.count" ] do
      delete request_path(@history_request)
    end
    assert_redirected_to request_path(@history_request)
    assert_match(/post-processing/i, flash[:alert])
  end

  test "admin can remove a stale library record then request another language" do
    sign_out
    sign_in_as(users(:two))
    File.unlink(@path)
    delete request_path(@history_request)
    assert_not Request.exists?(@history_request.id)
    assert @book.reload.acquired?, "history deletion must not implicitly discard library metadata"
    delete library_path(@book)
    assert_redirected_to library_index_path
    assert_not Book.exists?(@book.id)

    post requests_path, params: { work_id: "OL_HISTORY_RE_REQUEST", book_type: "ebook",
      title: "Completed", author: "Author", language: "de" }
    replacement = Request.joins(:book).find_by(books: { open_library_work_id: "OL_HISTORY_RE_REQUEST" })
    assert replacement, flash[:alert].to_s
    assert replacement.pending?
    assert_equal "de", replacement.language
    assert_redirected_to request_path(replacement)
  end
end
