# frozen_string_literal: true

require "application_system_test_case"

class UploadFormatsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    SettingsService.set(:allow_user_uploads, true)
    sign_in_as(users(:one))
  end

  test "folder selection retains new audio formats and skips unsupported files" do
    visit new_upload_path
    assert_selector "[data-upload-form-target='folderInput']", visible: :all
    page.execute_script <<~JS
      const transfer = new DataTransfer();
      transfer.items.add(new File(["new audio"], "New Book.FLAC", {type: "audio/flac"}));
      transfer.items.add(new File(["old audio"], "Existing Book.m4b", {type: "audio/mp4"}));
      transfer.items.add(new File(["notes"], "notes.txt", {type: "text/plain"}));
      const input = document.querySelector("[data-upload-form-target='folderInput']");
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", {bubbles: true}));
    JS

    assert_text "2 supported files selected from folder"
    assert_enqueued_jobs 2, only: UploadProcessingJob do
      click_button "Upload"
      assert_text "2 files uploaded successfully. Processing started."
    end
    assert_equal [ "Existing Book.m4b", "New Book.FLAC" ],
      Upload.where(user: users(:one)).order(:original_filename).pluck(:original_filename)
  end
end
