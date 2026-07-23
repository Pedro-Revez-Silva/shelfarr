# frozen_string_literal: true

require "test_helper"

class Admin::DetectedImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:two)
    sign_in_as(@admin)
  end

  test "index requires admin" do
    delete session_url
    get admin_detected_imports_url
    assert_response :redirect
  end

  test "index lists pending detections" do
    detection = create_detection(status: "detected", parsed_title: "Waiting For Review")

    get admin_detected_imports_url

    assert_response :success
    assert_select "div.font-medium", text: detection.display_title
  end

  test "index shows only a preview of the imported history when collapsed" do
    preview = Admin::DetectedImportsController::IMPORTED_PREVIEW_COUNT
    total = preview + 1
    total.times { |i| create_detection(status: "imported", parsed_title: "Imported Book #{i}") }

    get admin_detected_imports_url

    assert_response :success
    # Only the preview slice, plus the "show all" affordance and the truncation note.
    assert_select "turbo-frame#imported_history tbody tr", preview
    assert_select "turbo-frame#imported_history h2", text: /Imported\s+\(#{total}\)/
    assert_select "turbo-frame#imported_history a", text: /Show all \(#{total}\)/
    assert_select "turbo-frame#imported_history p", text: /Showing the #{preview} most recent of #{total}\./
  end

  test "index expands the full imported history with imported=all" do
    total = Admin::DetectedImportsController::IMPORTED_PREVIEW_COUNT + 1
    total.times { |i| create_detection(status: "imported", parsed_title: "Imported Book #{i}") }

    get admin_detected_imports_url(imported: "all")

    assert_response :success
    assert_select "turbo-frame#imported_history tbody tr", total
    assert_select "turbo-frame#imported_history a", text: /Show recent only/
  end

  test "scan enqueues a manual watched-folder scan when enabled" do
    enable_watched_folder_import

    assert_enqueued_with(job: WatchedFolderScanJob) do
      post scan_admin_detected_imports_url
    end

    assert_redirected_to admin_detected_imports_path
    assert_equal "Watched-folder scan started.", flash[:notice]
  end

  test "scan is rejected when watched-folder import is disabled" do
    set_setting("library_import_enabled", "false", "boolean", "import")

    assert_no_enqueued_jobs only: WatchedFolderScanJob do
      post scan_admin_detected_imports_url
    end

    assert_redirected_to admin_detected_imports_path
    assert_match(/Enable watched-folder import/, flash[:alert])
  end

  test "import queues the import job for an actionable detection" do
    detection = create_detection(status: "detected", parsed_title: "Ready To Import")

    assert_enqueued_with(job: DetectedImportJob, args: [ detection.id ]) do
      post import_admin_detected_import_url(detection)
    end

    assert_redirected_to admin_detected_imports_path
    assert_match(/Import queued/, flash[:notice])
  end

  test "dismiss moves an actionable detection out of the queue" do
    detection = create_detection(status: "detected", parsed_title: "Not Wanted")

    post dismiss_admin_detected_import_url(detection)

    assert_redirected_to admin_detected_imports_path
    assert_equal "dismissed", detection.reload.status
  end

  test "restore returns a dismissed detection to the review queue" do
    detection = create_detection(status: "dismissed", parsed_title: "Second Chance")

    post restore_admin_detected_import_url(detection)

    assert_redirected_to admin_detected_imports_path
    assert_equal "detected", detection.reload.status
  end

  test "undo reverses a completed import" do
    detection = create_detection(status: "imported", parsed_title: "Imported By Mistake")

    LibraryAcquisitionService.stub(:undo_import!, nil) do
      post undo_admin_detected_import_url(detection)
    end

    assert_redirected_to admin_detected_import_path(detection)
    assert_match(/Undid the import/, flash[:notice])
  end

  test "undo refuses a detection that was never imported" do
    detection = create_detection(status: "detected", parsed_title: "Never Imported")

    post undo_admin_detected_import_url(detection)

    assert_redirected_to admin_detected_imports_path
    assert_match(/nothing to undo/, flash[:alert])
  end

  private

  def create_detection(status:, parsed_title:)
    DetectedImport.create!(
      source_path: "/watched/#{parsed_title.parameterize}-#{SecureRandom.hex(4)}",
      status: status,
      book_type: "ebook",
      parsed_title: parsed_title,
      detected_at: Time.current
    )
  end

  def enable_watched_folder_import
    set_setting("library_import_enabled", "true", "boolean", "import")
    set_setting("library_import_path", Dir.mktmpdir("wf-controller"), "string", "import")
  end

  def set_setting(key, value, type, category)
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: type, category: category
    )
  end
end
