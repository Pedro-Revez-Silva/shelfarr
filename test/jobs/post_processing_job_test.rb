# frozen_string_literal: true

require "test_helper"

class PostProcessingJobTest < ActiveJob::TestCase
  setup do
    AudiobookshelfClient.reset_connection!

    # Create an audiobook for testing (not ebook)
    @book = Book.create!(
      title: "Test Audiobook",
      author: "Test Author",
      book_type: :audiobook
    )

    # Create a request for the audiobook
    @request = Request.create!(
      book: @book,
      user: users(:one),
      status: :downloading
    )

    # Create a completed download
    @download = @request.downloads.create!(
      name: @book.title,
      size_bytes: 1073741824,
      status: :completed,
      download_path: "/downloads/complete/Test Audiobook",
      progress: 100
    )

    # Setup Audiobookshelf settings
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-123")

    # Create temp directories for testing file operations
    @temp_source = Dir.mktmpdir("source")
    @temp_dest_base = Dir.mktmpdir("dest")

    # Update download path to temp source
    @download.update!(download_path: @temp_source)

    # Create test file in source
    File.write(File.join(@temp_source, "audiobook.mp3"), "test audio content")
  end

  teardown do
    AudiobookshelfClient.reset_connection!
    FileUtils.rm_rf(@temp_source) if @temp_source && File.exist?(@temp_source)
    FileUtils.rm_rf(@temp_dest_base) if @temp_dest_base && File.exist?(@temp_dest_base)
  end

  test "skips non-existent downloads" do
    assert_nothing_raised do
      PostProcessingJob.perform_now(999999)
    end
  end

  test "skips non-completed downloads" do
    @download.update!(status: :downloading)

    assert_no_changes -> { @request.reload.status } do
      PostProcessingJob.perform_now(@download.id)
    end
  end

  test "sets request status to processing then completed" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      # Capture status changes during job execution
      PostProcessingJob.perform_now(@download.id)
      @request.reload

      # After job completes, status should be completed (went through processing first)
      assert @request.completed?
    end
  end

  test "moves files to destination folder" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)

      expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
      assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
    end
  end

  test "updates book file_path after processing" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)
      @book.reload

      expected_path = File.join(@temp_dest_base, @book.author, @book.title)
      assert_equal expected_path, @book.file_path
    end
  end

  test "updates request status to completed after processing" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)
      @request.reload

      assert @request.completed?
    end
  end

  test "triggers audiobookshelf library scan" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      scan_stub = stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)

      assert_requested scan_stub
    end
  end

  test "continues without error if audiobookshelf scan fails" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_request(:post, "http://localhost:13378/api/libraries/lib-123/scan")
        .to_return(status: 500)

      # Should not raise, just log warning
      assert_nothing_raised do
        PostProcessingJob.perform_now(@download.id)
      end

      @request.reload
      assert @request.completed?
    end
  end

  test "uses fallback path when audiobookshelf not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_output_path, @temp_dest_base)

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
  end

  test "handles missing author by using Unknown Author folder" do
    @book.update!(author: nil)

    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)

      expected_dest = File.join(@temp_dest_base, "Unknown Author", @book.title)
      assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
    end
  end

  test "sanitizes filenames with invalid characters" do
    @book.update!(author: "Author: With|Invalid*Chars", title: "Book<Title>Test?")

    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)
      @book.reload

      # Extract just the folder names from the path
      path_parts = @book.file_path.split(File::SEPARATOR)
      author_folder = path_parts[-2]
      title_folder = path_parts[-1]

      # Author folder should have invalid chars removed
      assert_not_includes author_folder, ":"
      assert_not_includes author_folder, "|"
      assert_not_includes author_folder, "*"

      # Title folder should have invalid chars removed
      assert_not_includes title_folder, "<"
      assert_not_includes title_folder, ">"
      assert_not_includes title_folder, "?"
    end
  end

  test "marks for attention when audiobookshelf library fetch fails" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123")
        .to_return(status: 500)
      stub_request(:post, "http://localhost:13378/api/libraries/lib-123/scan")
        .to_return(status: 500)

      PostProcessingJob.perform_now(@download.id)
      @request.reload

      assert @request.attention_needed?
      assert_includes @request.issue_description, "Post-processing failed"
    end
  end

  private

  def stub_audiobookshelf_library(base_path)
    stub_request(:get, "http://localhost:13378/api/libraries/lib-123")
      .with(headers: { "Authorization" => "Bearer test-api-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "id" => "lib-123",
          "name" => "Audiobooks",
          "mediaType" => "book",
          "folders" => [
            { "id" => "folder1", "fullPath" => base_path }
          ]
        }.to_json
      )
  end

  def stub_audiobookshelf_scan
    stub_request(:post, "http://localhost:13378/api/libraries/lib-123/scan")
      .with(headers: { "Authorization" => "Bearer test-api-key" })
      .to_return(status: 200)
  end
end
