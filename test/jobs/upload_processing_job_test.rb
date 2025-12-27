# frozen_string_literal: true

require "test_helper"

class UploadProcessingJobTest < ActiveJob::TestCase
  setup do
    @user = users(:two)

    @temp_source = Dir.mktmpdir("source")
    @temp_audiobook_dest = Dir.mktmpdir("audiobooks")
    @temp_ebook_dest = Dir.mktmpdir("ebooks")

    Setting.find_or_create_by(key: "audiobook_output_path").update!(
      value: @temp_audiobook_dest,
      value_type: "string",
      category: "paths"
    )
    Setting.find_or_create_by(key: "ebook_output_path").update!(
      value: @temp_ebook_dest,
      value_type: "string",
      category: "paths"
    )
    # Disable Audiobookshelf
    Setting.where(key: "audiobookshelf_url").destroy_all

    # Create test file
    @test_file = File.join(@temp_source, "Brandon Sanderson - Mistborn.m4b")
    File.write(@test_file, "test audio content")

    @upload = Upload.create!(
      user: @user,
      original_filename: "Brandon Sanderson - Mistborn.m4b",
      file_path: @test_file,
      file_size: 100,
      status: :pending
    )
  end

  teardown do
    FileUtils.rm_rf(@temp_source) if @temp_source
    FileUtils.rm_rf(@temp_audiobook_dest) if @temp_audiobook_dest
    FileUtils.rm_rf(@temp_ebook_dest) if @temp_ebook_dest
  end

  test "processes upload and creates book" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      assert_difference "Book.count", 1 do
        UploadProcessingJob.perform_now(@upload.id)
      end

      @upload.reload
      assert @upload.completed?
      assert_equal "Mistborn", @upload.parsed_title
      assert_equal "Brandon Sanderson", @upload.parsed_author
      assert @upload.audiobook?
      assert @upload.book.present?
    end
  end

  test "moves file to correct location" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      UploadProcessingJob.perform_now(@upload.id)

      @upload.reload
      expected_path = File.join(@temp_audiobook_dest, "Brandon Sanderson", "Mistborn")

      assert File.exist?(File.join(expected_path, "Brandon Sanderson - Mistborn.m4b"))
      assert_equal expected_path, @upload.book.file_path
    end
  end

  test "handles ebook uploads" do
    VCR.turned_off do
      stub_open_library_search("Dune Frank Herbert")

      ebook_file = File.join(@temp_source, "Frank Herbert - Dune.epub")
      File.write(ebook_file, "test ebook content")

      upload = Upload.create!(
        user: @user,
        original_filename: "Frank Herbert - Dune.epub",
        file_path: ebook_file,
        file_size: 100,
        status: :pending
      )

      UploadProcessingJob.perform_now(upload.id)
      upload.reload

      assert upload.completed?
      assert upload.ebook?
      assert upload.book.ebook?

      expected_path = File.join(@temp_ebook_dest, "Frank Herbert", "Dune")
      assert_equal expected_path, upload.book.file_path
    end
  end

  test "matches existing book instead of creating new" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      existing = Book.create!(
        title: "Mistborn",
        author: "Brandon Sanderson",
        book_type: :audiobook
      )

      assert_no_difference "Book.count" do
        UploadProcessingJob.perform_now(@upload.id)
      end

      @upload.reload
      assert_equal existing, @upload.book
    end
  end

  test "handles failed processing due to missing file" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      FileUtils.rm(@test_file)

      UploadProcessingJob.perform_now(@upload.id)

      @upload.reload
      assert @upload.failed?
      assert @upload.error_message.present?
      assert_includes @upload.error_message, "Source file not found"
    end
  end

  test "skips non-pending uploads" do
    @upload.update!(status: :completed)

    assert_no_changes -> { @upload.reload.updated_at } do
      UploadProcessingJob.perform_now(@upload.id)
    end
  end

  test "skips non-existent uploads" do
    assert_nothing_raised do
      UploadProcessingJob.perform_now(999999)
    end
  end

  test "sets processed_at timestamp on success" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      UploadProcessingJob.perform_now(@upload.id)

      @upload.reload
      assert @upload.processed_at.present?
    end
  end

  test "updates match confidence from parser" do
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")

      UploadProcessingJob.perform_now(@upload.id)

      @upload.reload
      assert @upload.match_confidence.present?
      assert @upload.match_confidence > 0
    end
  end

  private

  def stub_open_library_search(query)
    # Stub Open Library search to return empty results
    # This allows tests to focus on file operations and book creation
    stub_request(:get, %r{https://openlibrary\.org/search\.json})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { numFound: 0, docs: [] }.to_json
      )
  end
end
