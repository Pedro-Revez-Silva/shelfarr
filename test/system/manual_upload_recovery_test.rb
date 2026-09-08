# frozen_string_literal: true

require "application_system_test_case"

class ManualUploadRecoveryTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @upload = Upload.create!(user: users(:two), original_filename: "unrecognized.m4b", status: :failed,
      parsed_title: "Wrong title", parsed_author: "Wrong author", error_message: "Automatic match failed")
    sign_in_as(users(:two))
  end

  test "administrator searches and selects a local book for a failed upload" do
    book = Book.create!(title: "The corrected title", author: "Corrected author", book_type: :audiobook)

    visit admin_upload_path(@upload)
    assert_text "Automatic match failed"
    fill_in "Search local books by title or author", with: "Corrected author"
    click_button "Search books"
    assert_text book.display_name
    assert_equal "Select #{book.display_name} and retry", find_button("Select and retry")["aria-label"]
    assert_enqueued_with(job: UploadProcessingJob, args: [ @upload.id ]) do
      click_button "Select and retry"
      assert_text "Manual match saved. Upload queued for retry."
    end

    assert_text "Manually Selected Book"
    assert_text book.display_name
    assert_no_text "Correct the match and retry"
    assert_equal book, @upload.reload.book
    assert @upload.manual_match?
    assert @upload.pending?
  end

  test "administrator creates corrected metadata and retries" do
    visit admin_upload_path(@upload)
    find("summary", text: "Create a book with corrected details").click
    fill_in "Title", with: "A corrected title"
    fill_in "Author (optional)", with: "A corrected author"

    assert_difference "Book.count", 1 do
      click_button "Create book and retry"
      assert_text "Manual match saved. Upload queued for retry."
    end

    assert_text "A corrected title"
    assert_text "A corrected author"
    assert @upload.reload.pending?
    assert @upload.manual_match?
    assert_equal "audiobook", @upload.book.book_type
  end

  test "reserved failed upload offers reconciliation without reassignment" do
    @upload.update!(destination_path: "/library/reserved-book.m4b")

    visit admin_upload_path(@upload)

    assert_text "Use Retry to reconcile it before changing the matched book."
    assert_no_text "Correct the match and retry"
    assert_button "Retry"
  end
end
