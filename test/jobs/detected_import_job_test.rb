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

  test "does not re-import a detection that is already imported" do
    detection = DetectedImport.create!(source_path: "/x", status: "imported")

    assert_no_difference "Book.count" do
      DetectedImportJob.perform_now(detection.id)
    end

    assert_equal "imported", detection.reload.status
  end

  private

  def set_setting(key, value)
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: "string", category: "paths"
    )
  end
end
