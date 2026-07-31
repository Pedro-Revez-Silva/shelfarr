# frozen_string_literal: true

require "test_helper"

class DetectedImportJobTest < ActiveJob::TestCase
  setup do
    @source_dir = Dir.mktmpdir("di-source")
    @ebook_dest = Dir.mktmpdir("di-ebooks")

    set_setting("ebook_output_path", @ebook_dest)
    set_setting("completed_download_import_mode", "copy")
    Setting.where(key: "audiobookshelf_url").destroy_all
  end

  teardown do
    [ @source_dir, @ebook_dest ].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  test "imports a detection and creates a book when there is no suggestion" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "dummy epub")
    detection = DetectedImport.create!(
      source_path: source, status: "detected", book_type: "ebook",
      parsed_title: "Elantris", parsed_author: "Brandon Sanderson"
    )

    assert_difference "Book.count", 1 do
      DetectedImportJob.perform_now(detection.id)
    end

    detection.reload
    assert_equal "imported", detection.status
    assert detection.imported_book.present?
    assert detection.imported_book.acquired?
    assert File.exist?(File.join(@ebook_dest, "Brandon Sanderson", "Elantris", "Brandon Sanderson - Elantris.epub"))
  end

  test "marks the detection failed when the source is missing" do
    detection = DetectedImport.create!(
      source_path: File.join(@source_dir, "gone.epub"), status: "detected", book_type: "ebook",
      parsed_title: "Gone", parsed_author: "Nobody"
    )

    DetectedImportJob.perform_now(detection.id)

    detection.reload
    assert_equal "failed", detection.status
    assert detection.error_message.present?
  end

  test "re-claims and imports a detection wedged in importing by a dead worker" do
    source = File.join(@source_dir, "Brandon Sanderson - Wedged.epub")
    File.write(source, "dummy epub")
    detection = DetectedImport.create!(
      source_path: source, status: "importing", book_type: "ebook",
      parsed_title: "Wedged", parsed_author: "Brandon Sanderson"
    )
    detection.update_column(:updated_at, 2.hours.ago)

    DetectedImportJob.perform_now(detection.id)

    assert_equal "imported", detection.reload.status
  end

  test "does not re-claim a freshly importing detection" do
    detection = DetectedImport.create!(source_path: "/x", status: "importing")

    assert_no_difference "Book.count" do
      DetectedImportJob.perform_now(detection.id)
    end

    assert_equal "importing", detection.reload.status
  end

  test "refuses to import a source that was replaced after it was detected" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "the approved book")
    stat = File.stat(source)
    detection = DetectedImport.create!(
      source_path: source, status: "detected", book_type: "ebook",
      parsed_title: "Elantris", parsed_author: "Brandon Sanderson",
      source_device: stat.dev, source_inode: stat.ino
    )

    # Atomically swap the approved path for different content on a new inode.
    replacement = File.join(@source_dir, "replacement.epub")
    File.write(replacement, "something else entirely")
    File.rename(replacement, source)

    DetectedImportJob.perform_now(detection.id)

    detection.reload
    assert_equal "failed", detection.status
    assert_empty Dir.glob(File.join(@ebook_dest, "**", "*.epub")),
      "the substituted bytes are never published under the approved title"
  end

  test "imports a source whose recorded identity still matches" do
    source = File.join(@source_dir, "Brandon Sanderson - Elantris.epub")
    File.write(source, "the approved book")
    stat = File.stat(source)
    detection = DetectedImport.create!(
      source_path: source, status: "detected", book_type: "ebook",
      parsed_title: "Elantris", parsed_author: "Brandon Sanderson",
      source_device: stat.dev, source_inode: stat.ino
    )

    DetectedImportJob.perform_now(detection.id)

    assert_equal "imported", detection.reload.status
    assert File.exist?(File.join(@ebook_dest, "Brandon Sanderson", "Elantris", "Brandon Sanderson - Elantris.epub"))
  end

  test "does not re-import a detection that is already imported" do
    detection = DetectedImport.create!(source_path: "/x", status: "imported")

    assert_no_difference "Book.count" do
      DetectedImportJob.perform_now(detection.id)
    end

    assert_equal "imported", detection.reload.status
  end

  test "each detection carries its own concurrency lease for the stuck window" do
    first = DetectedImport.create!(source_path: "/x", status: "detected")
    second = DetectedImport.create!(source_path: "/y", status: "detected")

    # A slow import is still running when the row looks stuck and the admin
    # recovers it; the lease makes the recovery attempt wait rather than reverse
    # the publication the original is finalizing.
    assert_equal 1, DetectedImportJob.concurrency_limit
    assert_equal DetectedImport::STUCK_IMPORTING_AFTER, DetectedImportJob.concurrency_duration
    assert_equal :block, DetectedImportJob.concurrency_on_conflict
    assert_equal(
      DetectedImportJob.new(first.id).concurrency_key,
      DetectedImportJob.new(first.id).concurrency_key
    )
    assert_not_equal(
      DetectedImportJob.new(first.id).concurrency_key,
      DetectedImportJob.new(second.id).concurrency_key,
      "unrelated detections still import in parallel"
    )
  end

  private

  def set_setting(key, value, type: "string", category: "import")
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: type, category: category
    )
  end
end
