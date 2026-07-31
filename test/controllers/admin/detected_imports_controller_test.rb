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

  test "index renders the scanning state while a scan is running" do
    create_detection(status: "detected", parsed_title: "Waiting For Review")

    WatchedFolderScanJob.stub(:scan_status, { state: "running", started_at: Time.current }) do
      get admin_detected_imports_url
    end

    assert_response :success
    assert_select "button[disabled][aria-busy=?]", "true", text: /Scanning/
    assert_select "svg.animate-spin", 2, "the shared spinner renders in the button and the status line"
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

  test "scan says so instead of claiming to start one while a scan is running" do
    enable_watched_folder_import

    # The job's concurrency key is declared on_conflict: :discard, so a second
    # scan enqueued now would be thrown away without ever running.
    assert_no_enqueued_jobs only: WatchedFolderScanJob do
      WatchedFolderScanJob.stub(:scanning_now?, true) do
        post scan_admin_detected_imports_url
      end
    end

    assert_redirected_to admin_detected_imports_path
    assert_match(/already running/, flash[:notice])
  end

  test "the disabled banner links to a settings tab that exists" do
    set_setting("library_import_enabled", "false", type: "boolean")

    get admin_detected_imports_url

    assert_response :success
    assert_select "a[href=?]", "#{admin_settings_path}#downloads", text: "Settings"
  end

  test "scan is rejected when watched-folder import is disabled" do
    set_setting("library_import_enabled", "false", type: "boolean")

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

  test "import retires the dead lease on a stuck row so the job can still claim it" do
    detection = create_detection(status: "importing", parsed_title: "Wedged Importing")
    detection.update_columns(updated_at: (DetectedImport::STUCK_IMPORTING_AFTER + 1.minute).ago)
    book = Book.create!(title: "Wedged Importing", book_type: :ebook)

    assert_enqueued_with(job: DetectedImportJob, args: [ detection.id ]) do
      post import_admin_detected_import_url(detection), params: { selection: "book:#{book.id}" }
    end

    assert_match(/Import queued/, flash[:notice])
    detection.reload
    assert_equal "failed", detection.status,
      "the expired lease is retired before the edit bumps updated_at back inside its window"
    assert_equal book, detection.suggested_book
    assert DetectedImport::ACTIONABLE_STATUSES.include?(detection.status),
      "and lands in a status DetectedImportJob#claim accepts outright"
  end

  test "import refuses a row a worker is still importing" do
    detection = create_detection(status: "importing", parsed_title: "Actively Importing")

    assert_no_enqueued_jobs only: DetectedImportJob do
      post import_admin_detected_import_url(detection)
    end

    assert_redirected_to admin_detected_imports_path
    assert_match(/can no longer be imported/, flash[:alert])
  end

  test "the queue's one-click Import submits the match the row displays" do
    detection = create_detection(status: "detected", parsed_title: "Wrongly Parsed Title")
    match = Book.create!(title: "The Real Title", author: "Brandon Sanderson", book_type: :ebook)
    detection.update!(candidate_books: [
      { "kind" => "library", "book_id" => match.id, "title" => "The Real Title", "score" => 99 }
    ])

    get admin_detected_imports_url

    assert_response :success
    assert_select "form[action=?] input[name=selection][value=?]",
      import_admin_detected_import_path(detection), "book:#{match.id}"

    # Following that form resolves the displayed candidate rather than falling
    # back to the filename parse and inventing a book from it.
    post import_admin_detected_import_url(detection), params: { selection: detection.default_selection }

    assert_equal match, detection.reload.suggested_book
  end

  test "rematch reads embedded metadata from inside an audiobook folder" do
    release = File.join(Dir.mktmpdir("wf-rematch"), "Warbreaker")
    FileUtils.mkdir_p(release)
    track = File.join(release, "01 - Chapter One.mp3")
    File.write(track, "chapter one bytes")
    detection = DetectedImport.create!(
      source_path: release, status: "detected", book_type: "audiobook", detected_at: Time.current
    )

    seen = {}
    identification = LibraryAcquisitionService::Identification.new(
      book_type: "audiobook", parsed_title: "Warbreaker", parsed_author: "Brandon Sanderson",
      suggested_book: nil, candidate_books: [], match_confidence: 50, source_path: track
    )
    LibraryAcquisitionService.stub(:identify, ->(**kwargs) { seen = kwargs; identification }) do
      post rematch_admin_detected_import_url(detection)
    end

    assert_equal track, seen[:source_path], "metadata is read from the release's audio file"
    assert_equal "Warbreaker", seen[:filename_hint], "but the filename parse still sees the release name"
    assert_equal "Brandon Sanderson", detection.reload.parsed_author
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

  test "remove refuses while the file is still in the watched folder" do
    file = File.join(Dir.mktmpdir("wf-remove"), "still-there.epub")
    File.write(file, "dummy epub")
    detection = DetectedImport.create!(
      source_path: file, status: "dismissed", book_type: "ebook", parsed_title: "Still There"
    )

    assert_no_difference "DetectedImport.count" do
      delete admin_detected_import_url(detection)
    end

    assert_redirected_to admin_detected_imports_path
    assert_match(/still in your watched folder/, flash[:alert],
      "removing the row would only hand the file back to the next scan")
  ensure
    FileUtils.rm_rf(File.dirname(file)) if file
  end

  test "remove prunes an entry whose source is gone" do
    detection = create_detection(status: "dismissed", parsed_title: "Long Gone")

    assert_difference "DetectedImport.count", -1 do
      delete admin_detected_import_url(detection)
    end

    assert_redirected_to admin_detected_imports_path
    assert_equal "Removed detection.", flash[:notice]
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
    set_setting("library_import_enabled", "true", type: "boolean")
    set_setting("library_import_path", Dir.mktmpdir("wf-controller"))
  end

  def set_setting(key, value, type: "string", category: "import")
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: type, category: category
    )
  end
end
