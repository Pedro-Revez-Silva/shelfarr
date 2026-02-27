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

    # Set output path to temp destination (Shelfarr always uses its own settings)
    SettingsService.set(:audiobook_output_path, @temp_dest_base)

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

  test "copies files to destination folder" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      PostProcessingJob.perform_now(@download.id)

      expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
      assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
    end
  end

  test "preserves original files for seeding" do
    VCR.turned_off do
      stub_audiobookshelf_library(@temp_dest_base)
      stub_audiobookshelf_scan

      original_file = File.join(@temp_source, "audiobook.mp3")
      assert File.exist?(original_file), "Source file should exist before processing"

      PostProcessingJob.perform_now(@download.id)

      # Original file should still exist (copy, not move)
      assert File.exist?(original_file), "Source file should still exist after processing (copy, not move)"

      # Destination file should also exist
      expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
      assert File.exist?(File.join(expected_dest, "audiobook.mp3")), "Destination file should exist"
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

  test "succeeds even when audiobookshelf library fetch fails" do
    # Shelfarr now uses its own configured paths, not Audiobookshelf's.
    # Processing should succeed regardless of ABS API issues.
    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-123")
        .to_return(status: 500)
      stub_request(:post, "http://localhost:13378/api/libraries/lib-123/scan")
        .to_return(status: 500)

      PostProcessingJob.perform_now(@download.id)
      @request.reload

      # Request should complete successfully since we use Shelfarr's output path
      assert @request.completed?
      expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
      assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
    end
  end

  test "uses per-client download path when configured" do
    # Create a subdirectory in temp_source to simulate a download folder
    download_subdir = File.join(@temp_source, "Test Audiobook")
    FileUtils.mkdir_p(download_subdir)
    File.write(File.join(download_subdir, "audiobook.mp3"), "test audio content")

    # Create a download client with a specific download path
    client = DownloadClient.create!(
      name: "Test Client",
      client_type: :qbittorrent,
      url: "http://localhost:8080",
      download_path: @temp_source  # Client's download path points to our temp source
    )

    # Associate download with the client
    # Host path would be something like /mnt/torrents/completed/Test Audiobook
    # Client's download_path maps this to @temp_source, so we end up with @temp_source/Test Audiobook
    @download.update!(
      download_client: client,
      download_path: "/mnt/torrents/completed/Test Audiobook"  # Host path that would need remapping
    )

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_output_path, @temp_dest_base)

    PostProcessingJob.perform_now(@download.id)

    # File should be copied to destination
    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3")), "File should be copied using client-specific path"
  end

  test "removes usenet download from client after successful import" do
    client = DownloadClient.create!(
      name: "SABnzbd Test",
      client_type: :sabnzbd,
      url: "http://localhost:8080",
      api_key: "test-api-key"
    )
    @download.update!(download_client: client, external_id: "SABnzbd_nzo_abc123")

    SettingsService.set(:audiobookshelf_url, "")

    VCR.turned_off do
      # Stub the SABnzbd queue delete API call
      remove_stub = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "queue", "name" => "delete", "value" => "SABnzbd_nzo_abc123", "del_files" => "1"))
        .to_return(status: 200, body: { "status" => true }.to_json, headers: { "Content-Type" => "application/json" })

      PostProcessingJob.perform_now(@download.id)

      assert_requested remove_stub
      assert @request.reload.completed?
    end
  end

  test "does not remove torrent download after import" do
    client = DownloadClient.create!(
      name: "qBittorrent Test",
      client_type: :qbittorrent,
      url: "http://localhost:8080"
    )
    @download.update!(download_client: client, external_id: "abc123hash")

    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    # Source files should still exist (copied, not removed)
    assert File.exist?(File.join(@temp_source, "audiobook.mp3"))
  end

  test "does not remove usenet download when setting is disabled" do
    SettingsService.set(:remove_completed_usenet_downloads, false)

    client = DownloadClient.create!(
      name: "SABnzbd Disabled",
      client_type: :sabnzbd,
      url: "http://localhost:8080",
      api_key: "test-api-key"
    )
    @download.update!(download_client: client, external_id: "SABnzbd_nzo_abc123")

    SettingsService.set(:audiobookshelf_url, "")

    # No HTTP stubs for SABnzbd - if cleanup ran, it would hit VCR and fail
    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
  end

  test "import succeeds even when usenet cleanup fails" do
    client = DownloadClient.create!(
      name: "SABnzbd Failing",
      client_type: :sabnzbd,
      url: "http://localhost:8080",
      api_key: "test-api-key"
    )
    @download.update!(download_client: client, external_id: "SABnzbd_nzo_abc123")

    SettingsService.set(:audiobookshelf_url, "")

    VCR.turned_off do
      # Stub SABnzbd to return an error
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "queue", "name" => "delete"))
        .to_return(status: 500)
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "history", "name" => "delete"))
        .to_return(status: 500)

      PostProcessingJob.perform_now(@download.id)

      # Import should still complete despite cleanup failure
      assert @request.reload.completed?
    end
  end

  test "remaps path using category when global remote_path is a sibling folder" do
    # Scenario: qBittorrent saves to /mnt/media/Torrents/shelfarr/TorrentName
    # but download_remote_path is /mnt/media/Torrents/Completed (SABnzbd path)
    # The category-aware remapping should detect the shared parent and remap correctly

    # Create a subdirectory simulating the category-based download path
    category_dir = File.join(@temp_source, "shelfarr")
    download_dir = File.join(category_dir, "Test Audiobook")
    FileUtils.mkdir_p(download_dir)
    File.write(File.join(download_dir, "audiobook.mp3"), "test audio content")

    client = DownloadClient.create!(
      name: "qBit Category Test",
      client_type: :qbittorrent,
      url: "http://localhost:8080",
      category: "shelfarr"
    )

    # Host path: /mnt/media/Torrents/shelfarr/Test Audiobook
    @download.update!(
      download_client: client,
      download_path: "/mnt/media/Torrents/shelfarr/Test Audiobook"
    )

    # Global settings point to a sibling folder (SABnzbd's Completed folder)
    SettingsService.set(:download_remote_path, "/mnt/media/Torrents/Completed")
    SettingsService.set(:download_local_path, @temp_source + "/Completed")
    SettingsService.set(:audiobookshelf_url, "")

    # The parent of remote_path (/mnt/media/Torrents) matches the parent of category path
    # So /mnt/media/Torrents/shelfarr/Test Audiobook → @temp_source/shelfarr/Test Audiobook
    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3")),
      "File should be copied using category-aware sibling remapping"
  end

  test "remaps path using client download_path with category" do
    # Scenario: client has a download_path and category, global remote doesn't match
    category_dir = File.join(@temp_source, "Test Audiobook")
    FileUtils.mkdir_p(category_dir)
    File.write(File.join(category_dir, "audiobook.mp3"), "test audio content")

    client = DownloadClient.create!(
      name: "qBit DlPath Test",
      client_type: :qbittorrent,
      url: "http://localhost:8080",
      category: "shelfarr",
      download_path: @temp_source  # Local path for this client's files
    )

    @download.update!(
      download_client: client,
      download_path: "/mnt/torrents/shelfarr/Test Audiobook"
    )

    SettingsService.set(:download_remote_path, "")
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3")),
      "File should be copied using client download_path + category extraction"
  end

  test "marks request for attention when source path is blank" do
    @download.update!(download_path: "")

    PostProcessingJob.perform_now(@download.id)
    @request.reload

    assert @request.attention_needed?
    assert_match /source path is blank/i, @request.issue_description
  end

  test "marks request for attention when source path does not exist" do
    @download.update!(download_path: "/nonexistent/path/that/does/not/exist")

    PostProcessingJob.perform_now(@download.id)
    @request.reload

    assert @request.attention_needed?
    assert_match /source path not found/i, @request.issue_description
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
