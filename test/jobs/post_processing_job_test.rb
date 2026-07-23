# frozen_string_literal: true

require "test_helper"
require "stringio"

class PostProcessingJobTest < ActiveJob::TestCase
  setup do
    LibraryPlatformClient.reset_connections!

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
    @temp_download_base = Dir.mktmpdir("downloads")
    @temp_source = File.join(@temp_download_base, "source")
    FileUtils.mkdir_p(@temp_source)
    @temp_dest_base = Dir.mktmpdir("dest")

    # Set output path to temp destination (Shelfarr always uses its own settings)
    SettingsService.set(:audiobook_output_path, @temp_dest_base)
    SettingsService.set(:download_local_path, @temp_download_base)
    SettingsService.set(:completed_download_import_mode, "copy")

    # Update download path to temp source
    @download.update!(download_path: @temp_source)

    # Create test file in source
    File.write(File.join(@temp_source, "audiobook.mp3"), "test audio content")
  end

  teardown do
    LibraryPlatformClient.reset_connections!
    FileUtils.rm_rf(@temp_download_base) if @temp_download_base && File.exist?(@temp_download_base)
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

  test "archive precreation failure does not skip later completion side effects" do
    completed_notifications = []
    library_scans = []
    job = PostProcessingJob.new

    LibraryDownloadArchiveService.stub(:call, ->(**) { raise LibraryDownloadArchiveService::Error, "archive failed" }) do
      job.stub(:trigger_library_scan, ->(book) { library_scans << book.id }) do
        NotificationService.stub(:request_completed, ->(request) { completed_notifications << request.id }) do
          job.send(:run_completion_side_effects, @request, @download, @book, @temp_source)
        end
      end
    end

    assert_equal [ @book.id ], library_scans
    assert_equal [ @request.id ], completed_notifications
  end

  test "refuses to import a shared download client root" do
    client = DownloadClient.create!(
      name: "Shared Deluge Root",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "deluge",
      category: "shelfarr",
      download_path: @temp_source
    )
    @download.update!(download_client: client)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    refute File.exist?(File.join(expected_dest, "audiobook.mp3"))
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "Refusing to import shared download root"
  end

  test "refuses to import a Deluge label category root when category casing differs" do
    # Deluge stores labels lowercase on disk; config may retain mixed case.
    category_root = File.join(@temp_source, "shelfarr")
    FileUtils.mkdir_p(category_root)
    File.write(File.join(category_root, "audiobook.mp3"), "test audio content")

    client = DownloadClient.create!(
      name: "Deluge Mixed Case Label",
      client_type: "deluge",
      url: "http://localhost:8112",
      password: "deluge",
      category: " Shelfarr ",
      download_path: @temp_source
    )
    @download.update!(download_client: client, download_path: category_root)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    refute File.exist?(File.join(expected_dest, "audiobook.mp3"))
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "Refusing to import shared download root"
  end

  test "refuses a download client path outside configured source roots" do
    unauthorized_source = Dir.mktmpdir("outside-download-root")
    secret_path = File.join(unauthorized_source, "credentials.sqlite3")
    File.binwrite(secret_path, "sensitive application data")
    @download.update!(download_path: unauthorized_source)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    refute File.exist?(File.join(expected_dest, "credentials.sqlite3"))
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "configured download root"
  ensure
    FileUtils.rm_rf(unauthorized_source) if unauthorized_source && File.exist?(unauthorized_source)
  end

  test "refuses a source symlink that escapes a configured download root" do
    unauthorized_source = Dir.mktmpdir("outside-download-root")
    File.binwrite(File.join(unauthorized_source, "credentials.sqlite3"), "sensitive application data")
    escaped_source = File.join(@temp_download_base, "escaped-source")
    File.symlink(unauthorized_source, escaped_source)
    @download.update!(download_path: escaped_source)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    refute File.exist?(File.join(expected_dest, "credentials.sqlite3"))
    assert @request.reload.attention_needed?
    assert_includes @request.issue_description, "configured download root"
  ensure
    FileUtils.rm_rf(unauthorized_source) if unauthorized_source && File.exist?(unauthorized_source)
  end

  test "skips a completed download replaced by a manual selection" do
    old_result = @request.search_results.create!(
      guid: "old-result",
      title: "Old result",
      magnet_url: "magnet:?xt=urn:btih:#{'a' * 40}",
      status: :selected
    )
    @download.update!(search_result: old_result)

    replacement = @request.add_manual_nzb!("https://downloads.example/replacement.nzb")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.downloading?
    assert replacement.search_result.reload.selected?
    assert_nil @download.reload.post_processing_job_id
    assert_nil @book.reload.file_path
  end

  test "skips a superseded completed download when no result remains selected" do
    old_result = @request.search_results.create!(
      guid: "superseded-result",
      title: "Superseded result",
      magnet_url: "magnet:?xt=urn:btih:#{'b' * 40}",
      status: :rejected
    )
    @download.update!(search_result: old_result)

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.downloading?
    assert_nil @download.reload.post_processing_job_id
    assert_nil @book.reload.file_path
  end

  test "library_id_for routes comic books to comic library" do
    SettingsService.set(:audiobookshelf_ebook_library_id, "ebook-lib")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "comic-lib")
    book = Book.create!(title: "Saga #1", author: "Brian K. Vaughan", book_type: :comicbook, content_kind: :graphic)

    assert_equal "comic-lib", PostProcessingJob.new.send(:library_id_for, book)
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

  test "copies audiobook files with UTF-8 names into UTF-8 destination paths" do
    SettingsService.set(:audiobookshelf_url, "")
    title = "The Reverse Centaur’s Guide to Life After AI"
    filename = "Cory Doctorow - #{title}.mp3"
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, filename), "unicode audio")
    @book.update!(title: title, author: "Cory Doctorow")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, title)
    assert @request.reload.completed?
    assert_equal "unicode audio", File.read(File.join(expected_dest, filename))
  end

  test "copies UTF-8 nested audiobook directories into UTF-8 destination paths" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")
    title = "The Reverse Centaur’s Guide to Life After AI"
    nested_directory = "Doctorow’s Extras"
    nested_source = File.join(@temp_source, nested_directory)
    FileUtils.mkdir_p(nested_source)
    FileUtils.mv(File.join(@temp_source, "audiobook.mp3"), File.join(nested_source, "afterword.mp3"))
    @book.update!(title: title, author: "Cory Doctorow")

    PostProcessingJob.perform_now(@download.id)

    expected_file = File.join(@temp_dest_base, @book.author, title, nested_directory, "afterword.mp3")
    assert @request.reload.completed?
    assert_equal "test audio content", File.read(expected_file)
    assert_not File.exist?(@temp_source)
  end

  test "keeps multi-file audiobook directory imports flat when bundle splitting is disabled" do
    SettingsService.set(:audiobookshelf_url, "")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert_equal expected_dest, @book.reload.file_path
    assert File.exist?(File.join(expected_dest, "Book One.m4b"))
    assert File.exist?(File.join(expected_dest, "Book Two.m4b"))
    assert_not File.exist?(File.join(@temp_dest_base, @book.author, "Book One", "Book One.m4b"))
  end

  test "splits multi-file audiobook directory imports into per-file path template folders when enabled" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book One.jpg"), "book one cover")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    File.write(File.join(@temp_source, "cover.png"), "shared cover")
    File.write(File.join(@temp_source, "README.md"), "release notes")

    PostProcessingJob.perform_now(@download.id)

    book_one_dest = File.join(@temp_dest_base, @book.author, "Book One")
    book_two_dest = File.join(@temp_dest_base, @book.author, "Book Two")
    request_dest = File.join(@temp_dest_base, @book.author, @book.title)

    assert_equal book_two_dest, @book.reload.file_path
    assert File.exist?(File.join(book_one_dest, "Book One.m4b"))
    assert File.exist?(File.join(book_one_dest, "Book One.jpg"))
    assert File.exist?(File.join(book_one_dest, "cover.png"))
    assert File.exist?(File.join(book_two_dest, "Book Two.m4b"))
    assert File.exist?(File.join(book_two_dest, "cover.png"))
    assert File.exist?(File.join(book_two_dest, "README.md"))
    assert_not File.exist?(File.join(book_two_dest, "Book One.jpg"))
    assert_not File.exist?(File.join(request_dest, "Book One.m4b"))
  end

  test "keeps chapter-based audiobook files together when bundle splitting is enabled" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    File.write(File.join(@temp_source, "02 - audiobook.mp3"), "second chapter")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert_equal expected_dest, @book.reload.file_path
    assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
    assert File.exist?(File.join(expected_dest, "02 - audiobook.mp3"))
  end

  test "splits audiobook bundles into subfolders even when audiobook path template is blank" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_path_template, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")

    PostProcessingJob.perform_now(@download.id)

    book_one_dest = File.join(@temp_dest_base, "Book One")
    book_two_dest = File.join(@temp_dest_base, "Book Two")

    assert_equal book_two_dest, @book.reload.file_path
    assert File.exist?(File.join(book_one_dest, "Book One.m4b"))
    assert File.exist?(File.join(book_two_dest, "Book Two.m4b"))
    assert_not File.exist?(File.join(@temp_dest_base, "Book One.m4b"))
  end

  test "copies audiobook files directly to output folder when path template is blank" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_path_template, "")

    PostProcessingJob.perform_now(@download.id)

    assert_equal @temp_dest_base, @book.reload.file_path
    assert File.exist?(File.join(@temp_dest_base, "audiobook.mp3"))
    assert_not File.exist?(File.join(@temp_dest_base, @book.author, @book.title, "audiobook.mp3"))
  end

  test "copies ebook files directly to output folder when path template is blank" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Dune.epub"))

    @book.update!(
      title: "Dune",
      author: "Frank Herbert",
      book_type: :ebook
    )

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:ebook_path_template, "")
    SettingsService.set(:ebook_filename_template, "{author} - {title}")

    PostProcessingJob.perform_now(@download.id)

    imported_file = File.join(@temp_dest_base, "Frank Herbert - Dune.epub")
    assert_equal imported_file, @book.reload.file_path
    assert File.exist?(imported_file)
    assert_not File.exist?(File.join(@temp_dest_base, "Frank Herbert", "Dune", "Frank Herbert - Dune.epub"))
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
      destination_file = File.join(expected_dest, "audiobook.mp3")
      assert File.exist?(destination_file), "Destination file should exist"
      refute_equal [ File.stat(original_file).dev, File.stat(original_file).ino ],
        [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    end
  end

  test "hardlinks directory imports and retains the source without scheduling cleanup" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    second_source = File.join(@temp_source, "second.mp3")
    File.write(second_source, "second audio content")

    output = FileCopyService.stub(:remove_source_tree, ->(*) { flunk "Hardlink imports must not schedule source cleanup" }) do
      capture_private_post_processing_logs do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    destination = File.join(@temp_dest_base, @book.author, @book.title)
    first_source = File.join(@temp_source, "audiobook.mp3")
    first_destination = File.join(destination, "audiobook.mp3")
    second_destination = File.join(destination, "second.mp3")

    assert @request.reload.completed?
    assert File.exist?(first_source)
    assert File.exist?(second_source)
    assert_equal [ File.stat(first_source).dev, File.stat(first_source).ino ],
      [ File.stat(first_destination).dev, File.stat(first_destination).ino ]
    assert_equal [ File.stat(second_source).dev, File.stat(second_source).ino ],
      [ File.stat(second_destination).dev, File.stat(second_destination).ino ]
    assert_includes output, "2 hardlinked, 0 copied after unsupported fallback, 0 reused"
  end

  test "hardlinks source aliases that share one inode" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    source_file = File.join(@temp_source, "audiobook.mp3")
    alias_source = File.join(@temp_source, "alternate-name.mp3")
    File.link(source_file, alias_source)

    output = capture_private_post_processing_logs do
      PostProcessingJob.perform_now(@download.id)
    end

    destination = File.join(@temp_dest_base, @book.author, @book.title)
    destination_file = File.join(destination, "audiobook.mp3")
    alias_destination = File.join(destination, "alternate-name.mp3")
    identity = [ File.stat(source_file).dev, File.stat(source_file).ino ]

    assert @request.reload.completed?
    assert File.exist?(source_file)
    assert File.exist?(alias_source)
    assert_equal identity, [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    assert_equal identity, [ File.stat(alias_destination).dev, File.stat(alias_destination).ino ]
    assert_includes output, "2 hardlinked, 0 copied after unsupported fallback, 0 reused"
  end

  test "hardlinks and renames a single file while retaining its source" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.write(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "hardlink")

    PostProcessingJob.perform_now(@download.id)

    destination_file = File.join(
      @temp_dest_base,
      @book.author,
      @book.title,
      "Test Author - Test Audiobook.m4b"
    )
    assert @request.reload.completed?
    assert File.exist?(source_file)
    assert_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
  end

  test "falls back only for unsupported hardlinks and logs private aggregate counts" do
    secret_title = "PRIVATE HARDLINK TITLE #{SecureRandom.hex(8)}"
    secret_filename = "private-hardlink-file-#{SecureRandom.hex(8)}.mp3"
    source_file = File.join(@temp_source, secret_filename)
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(source_file, "fallback audio content")
    @book.update!(title: secret_title)

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")

    output = FileCopyService.stub(:hardlink_noreplace, ->(*) {
      raise FileCopyService::HardlinkUnsupportedError, "unsupported at #{source_file}"
    }) do
      capture_private_post_processing_logs do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    destination_file = File.join(@temp_dest_base, @book.author, secret_title, secret_filename)
    assert @request.reload.completed?
    assert_equal "fallback audio content", File.binread(destination_file)
    assert File.exist?(source_file)
    refute_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    assert_includes output, "Hardlink unavailable for one file; falling back to a retained-source copy"
    assert_includes output, "0 hardlinked, 1 copied after unsupported fallback, 0 reused"
    refute_includes output, secret_title
    refute_includes output, secret_filename
    refute_includes output, @temp_source
    refute_includes output, @temp_dest_base
  end

  test "does not copy when hardlinking fails for a reason other than unsupported" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")

    FileCopyService.stub(:hardlink_noreplace, ->(*) { raise Errno::EACCES, "permission denied" }) do
      FileCopyService.stub(:cp_noreplace, ->(*) { flunk "Only unsupported hardlinks may fall back to copying" }) do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    assert @request.reload.attention_needed?
    assert File.exist?(File.join(@temp_source, "audiobook.mp3"))
  end

  test "hardlink collisions use a suffix without replacing library content" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    FileUtils.mkdir_p(destination)
    existing = File.join(destination, "audiobook.mp3")
    File.write(existing, "existing library content")

    PostProcessingJob.perform_now(@download.id)

    source_file = File.join(@temp_source, "audiobook.mp3")
    imported_file = File.join(destination, "audiobook (2).mp3")
    assert @request.reload.completed?
    assert_equal "existing library content", File.binread(existing)
    assert_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(imported_file).dev, File.stat(imported_file).ino ]
    assert File.exist?(source_file)
  end

  test "suffixes an identical independent destination won after private hardlink creation" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    source_file = File.join(@temp_source, "audiobook.mp3")
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    destination_file = File.join(destination, "audiobook.mp3")
    real_publish = FileCopyService.method(:publish_private_child_noreplace!)
    raced = false

    output = FileCopyService.stub(
      :publish_private_child_noreplace!,
      ->(parent, temporary, basename, identity, mode: FileCopyService::LIBRARY_FILE_MODE) {
        unless raced
          raced = true
          File.binwrite(File.join(destination, basename), "test audio content")
          raise Errno::EEXIST, basename
        end

        real_publish.call(parent, temporary, basename, identity, mode: mode)
      }
    ) do
      FileCopyService.stub(:secure_library_file!, ->(*) { flunk "Hardlink-mode reuse must never chmod the destination" }) do
        capture_private_post_processing_logs do
          PostProcessingJob.perform_now(@download.id)
        end
      end
    end

    assert raced
    assert @request.reload.completed?
    assert_equal "test audio content", File.binread(destination_file)
    assert File.exist?(source_file)
    refute_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    suffixed_file = File.join(destination, "audiobook (2).mp3")
    assert_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(suffixed_file).dev, File.stat(suffixed_file).ino ]
    assert_empty Dir.children(destination).grep(/\A\.shelfarr-copy-/)
    assert_includes output, "1 hardlinked, 0 copied after unsupported fallback, 0 reused"
  end

  test "hardlink retries reuse the existing source inode" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    source_file = File.join(@temp_source, "audiobook.mp3")
    File.chmod(0o744, source_file)
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    FileUtils.mkdir_p(destination)
    destination_file = File.join(destination, "audiobook.mp3")
    File.link(source_file, destination_file)

    output = FileCopyService.stub(:secure_library_file!, ->(*) { flunk "Hardlink-mode reuse must never chmod" }) do
      capture_private_post_processing_logs do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    assert @request.reload.completed?
    assert_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    assert_not File.exist?(File.join(destination, "audiobook (2).mp3"))
    assert_equal 0o744, File.stat(source_file).mode & 0o777
    assert_includes output, "0 hardlinked, 0 copied after unsupported fallback, 1 reused"
  end

  test "hardlink retries suffix an independent identical destination without chmod" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    source_file = File.join(@temp_source, "audiobook.mp3")
    File.chmod(0o744, source_file)
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    FileUtils.mkdir_p(destination)
    destination_file = File.join(destination, "audiobook.mp3")
    File.binwrite(destination_file, "test audio content")
    File.chmod(0o777, destination_file)

    output = FileCopyService.stub(:secure_library_file!, ->(*) { flunk "Hardlink-mode reuse must never chmod the destination" }) do
      capture_private_post_processing_logs do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    assert @request.reload.completed?
    refute_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(destination_file).dev, File.stat(destination_file).ino ]
    suffixed_file = File.join(destination, "audiobook (2).mp3")
    assert_equal [ File.stat(source_file).dev, File.stat(source_file).ino ],
      [ File.stat(suffixed_file).dev, File.stat(suffixed_file).ino ]
    assert_equal 0o744, File.stat(source_file).mode & 0o777
    assert_equal 0o777, File.stat(destination_file).mode & 0o777
    assert_includes output, "1 hardlinked, 0 copied after unsupported fallback, 0 reused"
  end

  test "hardlink retry reuses a secure fallback copy after interruption" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "hardlink")
    source_file = File.join(@temp_source, "audiobook.mp3")
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    destination_file = File.join(destination, "audiobook.mp3")
    hardlink_attempts = 0
    first_job = PostProcessingJob.new(@download.id)

    output = FileCopyService.stub(:hardlink_noreplace, ->(*) {
      hardlink_attempts += 1
      raise FileCopyService::HardlinkUnsupportedError, "simulated unsupported hardlink"
    }) do
      first_job.stub(:finalize_acquisition!, ->(*) { raise Interrupt, "simulated interruption" }) do
        assert_raises(Interrupt) { first_job.perform_now }
      end

      assert @request.reload.processing?
      assert_equal first_job.job_id, @download.reload.post_processing_job_id
      assert_equal 0o640, File.stat(destination_file).mode & 0o777

      retry_job = PostProcessingJob.new(@download.id, 0, first_job.job_id)
      FileCopyService.stub(:secure_library_file!, ->(*) { flunk "Hardlink-mode retry must never chmod" }) do
        capture_private_post_processing_logs do
          retry_job.perform_now
        end
      end
    end

    assert_equal 1, hardlink_attempts
    assert @request.reload.completed?
    assert File.exist?(source_file)
    assert_equal "test audio content", File.binread(destination_file)
    assert_not File.exist?(File.join(destination, "audiobook (2).mp3"))
    assert_includes output, "0 hardlinked, 0 copied after unsupported fallback, 1 reused"
  end

  test "hardlinks a shared sidecar into each split bundle destination" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "hardlink")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    book_one_source = File.join(@temp_source, "Book One.m4b")
    book_two_source = File.join(@temp_source, "Book Two.m4b")
    cover_source = File.join(@temp_source, "cover.png")
    File.write(book_one_source, "book one audio")
    File.write(book_two_source, "book two audio")
    File.write(cover_source, "shared cover")

    output = capture_private_post_processing_logs do
      PostProcessingJob.perform_now(@download.id)
    end

    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")
    book_two_destination = File.join(@temp_dest_base, @book.author, "Book Two")
    book_one_file = File.join(book_one_destination, "Book One.m4b")
    book_two_file = File.join(book_two_destination, "Book Two.m4b")
    book_one_cover = File.join(book_one_destination, "cover.png")
    book_two_cover = File.join(book_two_destination, "cover.png")

    assert @request.reload.completed?
    assert_equal [ File.stat(book_one_source).dev, File.stat(book_one_source).ino ],
      [ File.stat(book_one_file).dev, File.stat(book_one_file).ino ]
    assert_equal [ File.stat(book_two_source).dev, File.stat(book_two_source).ino ],
      [ File.stat(book_two_file).dev, File.stat(book_two_file).ino ]
    cover_identity = [ File.stat(cover_source).dev, File.stat(cover_source).ino ]
    assert_equal cover_identity, [ File.stat(book_one_cover).dev, File.stat(book_one_cover).ino ]
    assert_equal cover_identity, [ File.stat(book_two_cover).dev, File.stat(book_two_cover).ino ]
    assert File.exist?(book_one_source)
    assert File.exist?(book_two_source)
    assert File.exist?(cover_source)
    assert_includes output, "4 hardlinked, 0 copied after unsupported fallback, 0 reused"
  end

  test "copies a repeated shared sidecar after its second hardlink is unsupported" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "hardlink")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    book_one_source = File.join(@temp_source, "Book One.m4b")
    book_two_source = File.join(@temp_source, "Book Two.m4b")
    cover_source = File.join(@temp_source, "cover.png")
    File.write(book_one_source, "book one audio")
    File.write(book_two_source, "book two audio")
    File.write(cover_source, "shared cover")
    real_hardlink = FileCopyService.method(:hardlink_noreplace)
    cover_attempts = 0

    output = FileCopyService.stub(:hardlink_noreplace, ->(source, destination, **options) {
      if source == cover_source
        cover_attempts += 1
        if cover_attempts == 2
          raise FileCopyService::HardlinkUnsupportedError, "simulated unsupported second link"
        end
      end

      real_hardlink.call(source, destination, **options)
    }) do
      capture_private_post_processing_logs do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")
    book_two_destination = File.join(@temp_dest_base, @book.author, "Book Two")
    book_one_cover = File.join(book_one_destination, "cover.png")
    book_two_cover = File.join(book_two_destination, "cover.png")
    cover_identity = [ File.stat(cover_source).dev, File.stat(cover_source).ino ]

    assert @request.reload.completed?
    assert_equal 2, cover_attempts
    assert_equal cover_identity, [ File.stat(book_one_cover).dev, File.stat(book_one_cover).ino ]
    refute_equal cover_identity, [ File.stat(book_two_cover).dev, File.stat(book_two_cover).ino ]
    assert_equal "shared cover", File.binread(book_two_cover)
    assert File.exist?(cover_source)
    assert_includes output, "3 hardlinked, 1 copied after unsupported fallback, 0 reused"
  end

  test "moves directory imports when enabled" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    original_file = File.join(@temp_source, "audiobook.mp3")
    assert File.exist?(original_file), "Source file should exist before processing"

    FileCopyService.stub(:mv, ->(*) { flunk "Directory imports should copy entries, not move them individually" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3")), "Destination file should exist"
    assert_not File.exist?(original_file), "Source file should be removed after successful import"
    assert_not File.exist?(@temp_source), "Source download folder should be removed after successful import"
  end

  test "removes source directory after split audiobook bundle move import" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "move")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    File.write(File.join(@temp_source, ".bundle-metadata.json"), "release metadata")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert File.exist?(File.join(@temp_dest_base, @book.author, "Book One", "Book One.m4b"))
    assert File.exist?(File.join(@temp_dest_base, @book.author, "Book Two", "Book Two.m4b"))
    assert File.exist?(File.join(@temp_dest_base, @book.author, "Book Two", ".bundle-metadata.json"))
    assert_not File.exist?(@temp_source), "Source download folder should be removed after successful split import"
  end

  test "preserves hidden directories when bundle splitting falls back" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "move")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    hidden_directory = File.join(@temp_source, ".release-metadata")
    FileUtils.mkdir_p(hidden_directory)
    File.write(File.join(hidden_directory, "manifest.json"), "{}")

    PostProcessingJob.perform_now(@download.id)

    request_destination = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert File.exist?(File.join(request_destination, "Book One.m4b"))
    assert File.exist?(File.join(request_destination, ".release-metadata", "manifest.json"))
    assert_not File.exist?(@temp_source)
  end

  test "rejects split destinations inside the source before move cleanup" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_output_path, @temp_source)
    SettingsService.set(:audiobook_path_template, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "move")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    book_one_source = File.join(@temp_source, "Book One.m4b")
    book_two_source = File.join(@temp_source, "Book Two.m4b")
    File.write(book_one_source, "book one audio")
    File.write(book_two_source, "book two audio")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.attention_needed?
    assert_match(/destination overlaps/i, @request.issue_description)
    assert File.exist?(book_one_source)
    assert File.exist?(book_two_source)
    assert File.directory?(@temp_source)
  end

  test "retries partial split imports without duplicating identical files" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    File.write(File.join(@temp_source, "cover.png"), "shared cover")
    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")
    FileUtils.mkdir_p(book_one_destination)
    File.write(File.join(book_one_destination, "Book One.m4b"), "different existing audio")
    fail_book_two_once = true

    FileCopyService.stub(:cp_noreplace, ->(source, destination, **) {
      if File.basename(source) == "Book Two.m4b" && fail_book_two_once
        fail_book_two_once = false
        raise IOError, "simulated copy failure"
      end

      FileUtils.cp(source, destination)
    }) do
      first_job = PostProcessingJob.new(@download.id)
      first_job.perform_now
      assert @request.reload.attention_needed?

      @request.clear_attention!
      retry_job = PostProcessingJob.new(@download.id, 0, @download.reload.post_processing_job_id)
      retry_job.perform_now
    end

    book_two_destination = File.join(@temp_dest_base, @book.author, "Book Two")
    assert @request.reload.completed?
    assert_equal [ "Book One (2).m4b", "Book One.m4b", "cover.png" ], Dir.children(book_one_destination).sort
    assert_equal "book one audio", File.read(File.join(book_one_destination, "Book One (2).m4b"))
    assert_equal [ "Book Two.m4b", "cover.png" ], Dir.children(book_two_destination).sort
  end

  test "removes partial temporary files before retrying a split import" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one complete audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    fail_book_one_once = true
    real_copy = FileCopyService.method(:copy_source_io)

    FileCopyService.stub(:copy_source_io, ->(source, temporary) {
      if fail_book_one_once
        fail_book_one_once = false
        temporary.write("partial")
        temporary.flush
        raise IOError, "simulated interrupted copy"
      end

      real_copy.call(source, temporary)
    }) do
      first_job = PostProcessingJob.new(@download.id)
      first_job.perform_now
      assert @request.reload.attention_needed?

      @request.clear_attention!
      retry_job = PostProcessingJob.new(@download.id, 0, @download.reload.post_processing_job_id)
      retry_job.perform_now
    end

    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")
    assert @request.reload.completed?
    assert_equal [ "Book One.m4b" ], Dir.children(book_one_destination)
    assert_equal "book one complete audio", File.read(File.join(book_one_destination, "Book One.m4b"))
  end

  test "does not follow a destination symlink during split move imports" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "move")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    book_one_source = File.join(@temp_source, "Book One.m4b")
    File.write(book_one_source, "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")
    FileUtils.mkdir_p(book_one_destination)
    symlink_path = File.join(book_one_destination, "Book One.m4b")
    File.symlink(book_one_source, symlink_path)

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert File.symlink?(symlink_path)
    assert_equal "book one audio", File.read(File.join(book_one_destination, "Book One (2).m4b"))
    assert_not File.exist?(@temp_source)
  end

  test "does not overwrite a file created while publishing a split import" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    real_publish = FileCopyService.method(:publish_private_child_noreplace!)
    publish_race = true
    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")

    FileCopyService.stub(:publish_private_child_noreplace!, ->(parent, source, destination, identity) {
      if publish_race
        publish_race = false
        File.write(File.join(book_one_destination, destination), "concurrent file")
        raise Errno::EEXIST, destination
      end

      real_publish.call(parent, source, destination, identity)
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.completed?
    assert_equal "concurrent file", File.read(File.join(book_one_destination, "Book One.m4b"))
    assert_equal "book one audio", File.read(File.join(book_one_destination, "Book One (2).m4b"))
  end

  test "adds duplicate suffixes without exceeding the basename byte limit" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    long_filename = "#{'A' * 251}.m4b"
    File.write(File.join(@temp_source, long_filename), "long-name audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    long_title_destination = File.join(@temp_dest_base, @book.author, "A" * 100)
    FileUtils.mkdir_p(long_title_destination)
    File.write(File.join(long_title_destination, long_filename), "existing audio")

    PostProcessingJob.perform_now(@download.id)

    duplicate_filename = "#{'A' * 247} (2).m4b"
    assert @request.reload.completed?
    assert_equal 255, duplicate_filename.bytesize
    assert_equal "existing audio", File.read(File.join(long_title_destination, long_filename))
    assert_equal "long-name audio", File.read(File.join(long_title_destination, duplicate_filename))
  end

  test "publishes split imports when the destination filesystem rejects atomic publication" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")

    FileCopyService.stub(:native_linkat, ->(*) { raise Errno::EOPNOTSUPP, "hard links unavailable" }) do
      FileCopyService.stub(:native_rename_noreplace, false) do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One", "Book One.m4b")
    book_two_destination = File.join(@temp_dest_base, @book.author, "Book Two", "Book Two.m4b")
    assert @request.reload.completed?
    assert_equal "book one audio", File.read(book_one_destination)
    assert_equal "book two audio", File.read(book_two_destination)
  end

  test "does not overwrite a concurrent file when hard-link publication is unavailable" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    publish_race = true
    book_one_destination = File.join(@temp_dest_base, @book.author, "Book One")

    FileCopyService.stub(:native_linkat, ->(_source_fd, _source, _destination_fd, destination) {
      if publish_race
        publish_race = false
        File.write(File.join(book_one_destination, destination), "concurrent file")
      end
      raise Errno::EOPNOTSUPP, "hard links unavailable"
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.completed?
    assert_equal "concurrent file", File.read(File.join(book_one_destination, "Book One.m4b"))
    assert_equal "book one audio", File.read(File.join(book_one_destination, "Book One (2).m4b"))
  end

  test "reclaims interrupted temporary files after publication completed" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.m4b"), "book one complete audio")
    File.write(File.join(@temp_source, "Book Two.m4b"), "book two audio")
    book_one_directory = File.join(@temp_dest_base, @book.author, "Book One")
    FileUtils.mkdir_p(book_one_directory)
    book_one_destination = File.join(book_one_directory, "Book One.m4b")
    File.write(book_one_destination, "book one complete audio")
    token = "a" * 32
    temporary_path = File.join(book_one_directory, ".shelfarr-copy-#{token}.tmp")
    lock_path = File.join(book_one_directory, ".shelfarr-copy-#{token}.lock")
    File.write(temporary_path, "partial")
    temporary_stat = File.stat(temporary_path)
    File.write(
      lock_path,
      "#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:full:#{temporary_stat.dev}:#{temporary_stat.ino}"
    )

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert_equal "book one complete audio", File.read(book_one_destination)
    assert_not File.exist?(temporary_path)
    assert_not File.exist?(lock_path)
  end

  test "does not reclaim a temporary import owned by an active worker" do
    destination_directory = File.join(@temp_dest_base, @book.author, "Book One")
    FileUtils.mkdir_p(destination_directory)
    token = "b" * 32
    temporary_path = File.join(destination_directory, ".shelfarr-copy-#{token}.tmp")
    lock_path = File.join(destination_directory, ".shelfarr-copy-#{token}.lock")
    File.write(temporary_path, "active copy")

    File.open(lock_path, "w+") do |lock|
      temporary_stat = File.stat(temporary_path)
      lock.write(
        "#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:full:#{temporary_stat.dev}:#{temporary_stat.ino}"
      )
      lock.flush
      lock.flock(File::LOCK_EX)

      FileCopyService.cleanup_interrupted_copies(destination_directory)

      assert_equal "active copy", File.read(temporary_path)
      assert File.exist?(lock_path)
    end
  end

  test "keeps exact-stem companions with each split book during move import" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:split_audiobook_bundle_imports, true)
    SettingsService.set(:completed_download_import_mode, "move")
    @book.update!(title: "Book Two")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    File.write(File.join(@temp_source, "Book One.aax"), "book one audio")
    File.write(File.join(@temp_source, "Book One.pdf"), "book one companion")
    File.write(File.join(@temp_source, "Book Two.aax"), "book two audio")
    File.write(File.join(@temp_source, "Book Two.pdf"), "book two companion")

    PostProcessingJob.perform_now(@download.id)

    book_one_dest = File.join(@temp_dest_base, @book.author, "Book One")
    book_two_dest = File.join(@temp_dest_base, @book.author, "Book Two")
    assert @request.reload.completed?
    assert File.exist?(File.join(book_one_dest, "Book One.aax"))
    assert File.exist?(File.join(book_one_dest, "Book One.pdf"))
    assert File.exist?(File.join(book_two_dest, "Book Two.aax"))
    assert File.exist?(File.join(book_two_dest, "Book Two.pdf"))
    assert_not File.exist?(@temp_source)
  end

  test "moves and renames single file imports when enabled" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.write(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")

    FileCopyService.stub(:cp, ->(*) { flunk "Single-file move imports should not copy files" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.m4b"))
    assert_not File.exist?(source_file), "Source file should no longer exist after move import"
  end

  test "single-file move retains its source until database finalization" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")
    first_job = PostProcessingJob.new(@download.id)

    first_job.stub(:finalize_acquisition!, ->(*) { raise Interrupt, "simulated hard kill" }) do
      assert_raises(Interrupt) { first_job.perform_now }
    end

    destination = File.join(
      @temp_dest_base,
      @book.author,
      @book.title,
      "Test Author - Test Audiobook.m4b"
    )
    assert File.exist?(source_file)
    assert_equal "single file audio content", File.binread(destination)
    assert @request.reload.processing?

    retry_job = PostProcessingJob.new(@download.id, 0, first_job.job_id)
    retry_job.perform_now

    assert @request.reload.completed?
    assert_not File.exist?(source_file)
    assert_equal [ "Test Author - Test Audiobook.m4b" ], Dir.children(File.dirname(destination))
  end

  test "single-file move removes its source after reusing an identical destination" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")
    destination_directory = File.join(@temp_dest_base, @book.author, @book.title)
    destination = File.join(destination_directory, "Test Author - Test Audiobook.m4b")
    FileUtils.mkdir_p(destination_directory)
    File.binwrite(destination, "single file audio content")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert_not File.exist?(source_file)
    assert_equal [ "Test Author - Test Audiobook.m4b" ], Dir.children(destination_directory)
  end

  test "single-file move retains its source when a reused destination is replaced" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")
    destination_directory = File.join(@temp_dest_base, @book.author, @book.title)
    destination = File.join(destination_directory, "Test Author - Test Audiobook.m4b")
    displaced = File.join(destination_directory, "displaced.m4b")
    FileUtils.mkdir_p(destination_directory)
    File.binwrite(destination, "single file audio content")
    real_comparison = FileCopyService.method(:same_file_content?)
    replaced = false

    comparison = lambda do |*args, **kwargs|
      identical = real_comparison.call(*args, **kwargs)
      if identical && !replaced
        replaced = true
        File.rename(destination, displaced)
        File.binwrite(destination, "unrelated replacement")
      end
      identical
    end

    FileCopyService.stub(:same_file_content?, comparison) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert replaced
    assert @request.reload.attention_needed?
    assert_equal "single file audio content", File.binread(source_file)
    assert_equal "unrelated replacement", File.binread(destination)
  end

  test "single-file move recovery completes cleanup after a post-commit interruption" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")
    job = PostProcessingJob.new(@download.id)

    job.stub(:remove_import_source, ->(*) { raise Interrupt, "simulated post-commit interruption" }) do
      assert_raises(Interrupt) { job.perform_now }
    end

    assert @request.reload.completed?
    assert File.exist?(source_file)
    assert @download.reload.post_processing_cleanup_state.present?

    PostProcessingRecoveryJob.perform_now

    assert_not File.exist?(source_file)
    assert_nil @download.reload.post_processing_cleanup_state
  end

  test "single-file move retains its source when the destination changes after finalization" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")
    destination = File.join(
      @temp_dest_base,
      @book.author,
      @book.title,
      "Test Author - Test Audiobook.m4b"
    )
    job = PostProcessingJob.new(@download.id)
    real_finalize = job.method(:finalize_acquisition!)

    finalizing = lambda do |*args|
      finalized = real_finalize.call(*args)
      File.binwrite(destination, "replacement after finalization") if finalized
      finalized
    end

    job.stub(:finalize_acquisition!, finalizing) { job.perform_now }

    assert @request.reload.completed?
    assert_equal "single file audio content", File.binread(source_file)
    assert_equal "replacement after finalization", File.binread(destination)
    assert_nil @download.reload.post_processing_cleanup_state
  end

  test "single-file move retains its source when destination fsync is unsupported" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    FileCopyService.stub(:sync_io, false) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.attention_needed?
    assert_match(/fsync is unsupported/i, @request.issue_description)
    assert File.exist?(source_file)
  end

  test "single-file copy accepts safe mode when chmod is ignored" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)
    SettingsService.set(:audiobookshelf_url, "")

    FileCopyService.stub(:native_fchmod, ->(*) { }) do
      PostProcessingJob.perform_now(@download.id)
    end

    destination = Dir.glob(File.join(@temp_dest_base, @book.author, @book.title, "*.m4b")).sole
    assert @request.reload.completed?
    assert_equal 0o600, File.stat(destination).mode & 0o777
  end

  test "falls back to buffered move when NFS copy_file_range fails for single files" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.write(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    @download.update!(download_path: source_file)

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    SettingsService.set(:completed_download_import_mode, "move")

    IO.stub(:copy_stream, ->(*) { raise Errno::EACCES, "copy_file_range" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.m4b"))
    assert_not File.exist?(source_file), "Source file should be removed after buffered move fallback"
  end

  test "keeps source file when move import fails" do
    failing_file = File.join(@temp_source, "fail.mp3")
    File.write(failing_file, "copy failure")
    @download.update!(download_path: failing_file)

    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    FileCopyService.stub(:cp_noreplace, ->(*) { raise Errno::EACCES, "permission denied" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.attention_needed?
    assert File.exist?(failing_file), "Failing file should remain in source after failure"
  end

  test "moves ebook directory imports and removes nested source entries when enabled" do
    FileUtils.rm_rf(@temp_source)
    nested_source = File.join(@temp_source, "Calibre Export")
    FileUtils.mkdir_p(nested_source)
    write_valid_ebook_file(File.join(nested_source, "Jurassic Park by Michael Crichton.epub"))
    File.binwrite(File.join(nested_source, "cover.jpg"), "\xFF\xD8\xFFvalid cover content".b)

    @book.update!(
      title: "Jurassic Park",
      author: "Michael Crichton",
      book_type: :ebook,
      year: 1990
    )

    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:ebook_path_template, "{author}/{title}")
    SettingsService.set(:ebook_filename_template, "{author} - {title} ({year})")
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    FileCopyService.stub(:mv, ->(*) { flunk "Ebook directory imports should copy files, not move them individually" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    expected_dest = File.join(@temp_dest_base, "Michael Crichton", "Jurassic Park")
    assert @request.reload.completed?
    assert File.exist?(File.join(expected_dest, "Michael Crichton - Jurassic Park (1990).epub"))
    assert File.exist?(File.join(expected_dest, "cover.jpg"))
    assert_not File.exist?(nested_source), "Nested ebook source folder should be removed after a move import"
    assert_not File.exist?(@temp_source), "Ebook source folder should be removed after a move import"
  end

  test "imports every snapshotted file even when a later live directory listing omits one" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")
    File.binwrite(File.join(@temp_source, "second.mp3"), "second expected chapter")
    real_children = Dir.method(:children)

    omit_second_from_live_source_listing = lambda do |path, *arguments|
      if File.expand_path(path.to_s) == File.expand_path(@temp_source)
        [ "audiobook.mp3" ]
      else
        real_children.call(path, *arguments)
      end
    end

    Dir.stub(:children, omit_second_from_live_source_listing) do
      PostProcessingJob.perform_now(@download.id)
    end

    destination = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert_equal "test audio content", File.binread(File.join(destination, "audiobook.mp3"))
    assert_equal "second expected chapter", File.binread(File.join(destination, "second.mp3"))
    assert_not File.exist?(@temp_source)
  end

  test "keeps source directory intact when directory import fails with move enabled" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    File.write(File.join(@temp_source, "second.mp3"), "second file")
    original_file = File.join(@temp_source, "audiobook.mp3")

    real_copy = FileCopyService.method(:cp_noreplace)
    FileCopyService.stub(:cp_noreplace, ->(source, destination, **options) {
      raise "import failed" if File.basename(source) == "second.mp3"

      real_copy.call(source, destination, **options)
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.attention_needed?
    imported_file = File.join(@temp_dest_base, @book.author, @book.title, "audiobook.mp3")
    assert_equal "test audio content", File.binread(imported_file)
    assert File.exist?(original_file), "First source file should remain when a later import fails"
    assert File.exist?(File.join(@temp_source, "second.mp3")), "Failing source file should remain after partial import"
    assert File.exist?(@temp_source), "Source download folder should remain after failed import"
  end

  test "directory imports never overwrite an existing library file" do
    SettingsService.set(:audiobookshelf_url, "")
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    FileUtils.mkdir_p(destination)
    existing = File.join(destination, "audiobook.mp3")
    File.binwrite(existing, "existing Audible publication")

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert_equal "existing Audible publication", File.binread(existing)
    assert_equal "test audio content", File.binread(File.join(destination, "audiobook (2).mp3"))
  end

  test "directory retries reuse an identical published file and enforce its safe mode" do
    SettingsService.set(:audiobookshelf_url, "")
    destination = File.join(@temp_dest_base, @book.author, @book.title)
    FileUtils.mkdir_p(destination)
    existing = File.join(destination, "audiobook.mp3")
    File.binwrite(existing, "test audio content")
    File.chmod(0o777, existing)

    PostProcessingJob.perform_now(@download.id)

    assert @request.reload.completed?
    assert_equal [ "audiobook.mp3" ], Dir.children(destination)
    assert_equal "test audio content", File.binread(existing)
    assert_equal 0o640, File.stat(existing).mode & 0o777
  end

  test "rejects symbolic links and fifo entries anywhere in a recursive source" do
    SettingsService.set(:audiobookshelf_url, "")
    nested = File.join(@temp_source, "nested")
    FileUtils.mkdir_p(nested)
    File.symlink(File.join(@temp_source, "audiobook.mp3"), File.join(nested, "linked.mp3"))
    File.mkfifo(File.join(@temp_source, "release.pipe"))

    PostProcessingJob.perform_now(@download.id)

    destination = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.attention_needed?
    assert_match(/symbolic link or non-regular path/i, @request.issue_description)
    assert_not File.exist?(destination)
  end

  test "never imports outside bytes after the download root is swapped" do
    SettingsService.set(:audiobookshelf_url, "")
    File.binwrite(File.join(@temp_source, "second.mp3"), "second expected chapter")
    displaced_source = "#{@temp_source}-displaced"
    outside = Dir.mktmpdir("outside-source")
    File.binwrite(File.join(outside, "audiobook.mp3"), "outside audiobook bytes")
    File.binwrite(File.join(outside, "second.mp3"), "outside second bytes")
    real_copy = FileCopyService.method(:copy_source_io)
    swapped = false

    FileCopyService.stub(:copy_source_io, ->(source, temporary) {
      real_copy.call(source, temporary)
      unless swapped
        swapped = true
        File.rename(@temp_source, displaced_source)
        File.symlink(outside, @temp_source)
      end
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    destination = File.join(@temp_dest_base, @book.author, @book.title)
    imported_contents = Dir.glob(File.join(destination, "**", "*"))
      .select { |path| File.file?(path) }
      .map { |path| File.binread(path) }
    assert @request.reload.attention_needed?
    assert_not imported_contents.any? { |content| content.start_with?("outside") }
    assert_equal "outside audiobook bytes", File.binread(File.join(outside, "audiobook.mp3"))
  ensure
    FileUtils.rm_f(@temp_source) if @temp_source && File.symlink?(@temp_source)
    FileUtils.rm_rf(displaced_source) if displaced_source
    FileUtils.rm_rf(outside) if outside
  end

  test "rejects a source swapped outside its authorized root before snapshot" do
    SettingsService.set(:audiobookshelf_url, "")
    displaced_source = "#{@temp_source}-authorized"
    outside = Dir.mktmpdir("outside-authorized-source")
    File.binwrite(File.join(outside, "audiobook.mp3"), "outside audiobook bytes")
    real_snapshot = FileCopyService.method(:snapshot_source_root)
    swapped = false

    snapshotting = lambda do |path, **options|
      unless swapped
        swapped = true
        File.rename(@temp_source, displaced_source)
        File.symlink(outside, @temp_source)
      end
      real_snapshot.call(path, **options)
    end

    FileCopyService.stub(:snapshot_source_root, snapshotting) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert swapped
    assert @request.reload.attention_needed?
    assert_match(/outside configured download roots/i, @request.issue_description)
    imported = Dir.glob(File.join(@temp_dest_base, "**", "*"))
      .select { |path| File.file?(path) }
    assert_empty imported
    assert_equal "outside audiobook bytes", File.binread(File.join(outside, "audiobook.mp3"))
  ensure
    FileUtils.rm_f(@temp_source) if @temp_source && File.symlink?(@temp_source)
    FileUtils.rm_rf(displaced_source) if displaced_source
    FileUtils.rm_rf(outside) if outside
  end

  test "preserves both files and asks for review when another acquisition wins the book claim" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")
    existing_path = File.join(@temp_dest_base, "already-owned", "existing.m4b")
    FileUtils.mkdir_p(File.dirname(existing_path))
    File.binwrite(existing_path, "existing acquisition")
    imported_path = File.join(@temp_dest_base, @book.author, @book.title)
    job = PostProcessingJob.new(@download.id)
    real_finalize = job.method(:finalize_acquisition!)

    job.stub(:finalize_acquisition!, ->(download, request, book, path, cleanup_state = nil) {
      Book.where(id: book.id).update_all(file_path: existing_path, updated_at: Time.current)
      real_finalize.call(download, request, book, path, cleanup_state)
    }) do
      job.perform_now
    end

    assert @request.reload.attention_needed?
    assert_equal existing_path, @book.reload.file_path
    assert_equal "existing acquisition", File.binread(existing_path)
    assert_equal "test audio content", File.binread(File.join(imported_path, "audiobook.mp3"))
    assert File.exist?(@temp_source), "the source must remain until the claim is reconciled"
    assert_includes @request.issue_description, "different library file"
  end

  test "completes request when import source removal fails non-fatally" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:completed_download_import_mode, "move")

    FileCopyService.stub(:remove_source_tree, ->(*) { raise Errno::EACCES, "permission denied" }) do
      PostProcessingJob.perform_now(@download.id)
    end

    @request.reload
    assert @request.completed?
    assert_not @request.attention_needed?

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
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

  test "retains a usenet download when destination fsync is unsupported" do
    client = DownloadClient.create!(
      name: "SABnzbd durability test",
      client_type: :sabnzbd,
      url: "http://localhost:8080",
      api_key: "test-api-key"
    )
    @download.update!(download_client: client, external_id: "SABnzbd_nzo_durable")
    SettingsService.set(:audiobookshelf_url, "")

    VCR.turned_off do
      remove_stub = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "queue", "name" => "delete"))
        .to_return(status: 200, body: { "status" => true }.to_json)

      FileCopyService.stub(:sync_io, false) do
        PostProcessingJob.perform_now(@download.id)
      end

      assert_not_requested remove_stub
    end

    assert @request.reload.attention_needed?
    assert_match(/fsync is unsupported/i, @request.issue_description)
    assert File.exist?(File.join(@temp_source, "audiobook.mp3"))
  end

  test "retains a usenet download when its destination changes after finalization" do
    source_file = File.join(@temp_source, "Original Name.m4b")
    File.binwrite(source_file, "single file audio content")
    FileUtils.rm_f(File.join(@temp_source, "audiobook.mp3"))
    client = DownloadClient.create!(
      name: "SABnzbd destination validation",
      client_type: :sabnzbd,
      url: "http://localhost:8080",
      api_key: "test-api-key"
    )
    @download.update!(
      download_path: source_file,
      download_client: client,
      external_id: "SABnzbd_nzo_replaced"
    )
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_filename_template, "{author} - {title}")
    destination = File.join(
      @temp_dest_base,
      @book.author,
      @book.title,
      "Test Author - Test Audiobook.m4b"
    )
    job = PostProcessingJob.new(@download.id)
    real_finalize = job.method(:finalize_acquisition!)

    finalizing = lambda do |*args|
      finalized = real_finalize.call(*args)
      File.binwrite(destination, "replacement after finalization") if finalized
      finalized
    end

    VCR.turned_off do
      remove_stub = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "queue", "name" => "delete"))
        .to_return(status: 200, body: { "status" => true }.to_json)

      job.stub(:finalize_acquisition!, finalizing) { job.perform_now }

      assert_not_requested remove_stub
    end

    assert @request.reload.completed?
    assert_equal "single file audio content", File.binread(source_file)
    assert_equal "replacement after finalization", File.binread(destination)
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

  test "remaps Windows download path backslashes after global prefix replacement" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Windows Book.epub"))

    @book.update!(book_type: :ebook)
    @download.update!(download_path: "D:\\QbittorrentMove\\Windows Book.epub")

    SettingsService.set(:download_remote_path, "D:\\QbittorrentMove")
    SettingsService.set(:download_local_path, @temp_source)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.epub")),
      "Windows backslashes should be converted to container path separators"
  end

  test "renames ebook files copied from a source directory" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Jurassic Park by Michael Crichton.epub"))

    @book.update!(
      title: "Jurassic Park",
      author: "Michael Crichton",
      book_type: :ebook,
      year: 1990
    )

    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:ebook_path_template, "{author}/{title}")
    SettingsService.set(:ebook_filename_template, "{author} - {title} ({year})")
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, "Michael Crichton", "Jurassic Park")
    assert File.exist?(File.join(expected_dest, "Michael Crichton - Jurassic Park (1990).epub")),
      "Ebook file from a directory source should use the filename template"
    assert_not File.exist?(File.join(expected_dest, "Jurassic Park by Michael Crichton.epub")),
      "Original ebook filename should not be copied into the library"
  end

  test "renames ebook files copied from nested source directories" do
    FileUtils.rm_rf(@temp_source)
    nested_source = File.join(@temp_source, "Calibre Export")
    FileUtils.mkdir_p(nested_source)
    write_valid_ebook_file(File.join(nested_source, "Jurassic Park by Michael Crichton.epub"))

    @book.update!(
      title: "Jurassic Park",
      author: "Michael Crichton",
      book_type: :ebook,
      year: 1990
    )

    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:ebook_path_template, "{author}/{title}")
    SettingsService.set(:ebook_filename_template, "{author} - {title} ({year})")
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, "Michael Crichton", "Jurassic Park")
    assert File.exist?(File.join(expected_dest, "Michael Crichton - Jurassic Park (1990).epub")),
      "Nested ebook file should use the filename template"
    assert_not File.exist?(File.join(expected_dest, "Calibre Export")),
      "Nested source folder should not be copied when it only contained renamed ebook files"
    assert_not File.exist?(File.join(expected_dest, "Calibre Export", "Jurassic Park by Michael Crichton.epub")),
      "Nested original ebook filename should not be copied into the library"
  end

  test "copies nested ebook sidecars beside the renamed ebook" do
    FileUtils.rm_rf(@temp_source)
    nested_source = File.join(@temp_source, "Calibre Export")
    FileUtils.mkdir_p(nested_source)
    write_valid_ebook_file(File.join(nested_source, "Jurassic Park by Michael Crichton.epub"))
    File.binwrite(File.join(nested_source, "cover.jpg"), "\xFF\xD8\xFFvalid cover content".b)

    @book.update!(
      title: "Jurassic Park",
      author: "Michael Crichton",
      book_type: :ebook,
      year: 1990
    )

    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:ebook_path_template, "{author}/{title}")
    SettingsService.set(:ebook_filename_template, "{author} - {title} ({year})")
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, "Michael Crichton", "Jurassic Park")
    assert File.exist?(File.join(expected_dest, "Michael Crichton - Jurassic Park (1990).epub"))
    assert File.exist?(File.join(expected_dest, "cover.jpg"))
    assert_not File.exist?(File.join(expected_dest, "Calibre Export"))
  end

  test "copies UTF-8 ebook sidecar names into UTF-8 destination paths" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    title = "The Reverse Centaur’s Guide to Life After AI"
    sidecar = "Doctorow’s Notes.nfo"
    write_valid_ebook_file(File.join(@temp_source, "book.epub"))
    File.write(File.join(@temp_source, sidecar), "release notes")

    @book.update!(title: title, author: "Cory Doctorow", book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, title)
    assert @request.reload.completed?
    assert_equal "release notes", File.read(File.join(expected_dest, sidecar))
    assert File.exist?(File.join(expected_dest, "Cory Doctorow - #{title}.epub"))
  end

  test "imports bundled DjVu ebooks" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Bundled Book.djvu"))

    @book.update!(book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.djvu"))
  end

  test "imports ebook directories with non UTF-8 nfo sidecars" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Valid Book.epub"))
    File.binwrite(File.join(@temp_source, "release.nfo"), "Release Info\n" + 0xB3.chr)

    @book.update!(book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.epub"))
    assert File.exist?(File.join(expected_dest, "release.nfo"))
  end

  test "remaps Windows download path when remote path uses forward slashes" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Forward Remote.mobi"))

    @book.update!(book_type: :ebook)
    @download.update!(download_path: "D:\\QbittorrentMove\\Forward Remote.mobi")

    SettingsService.set(:download_remote_path, "D:/QbittorrentMove")
    SettingsService.set(:download_local_path, @temp_source)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.mobi")),
      "Windows client paths should match normalized remote path mappings"
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

  test "retries later when source path is not visible yet" do
    FileUtils.rm_rf(@temp_source)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:post_processing_source_path_retries, 2)

    retry_args = ->(args) { args.first(2) == [ @download.id, 1 ] && args.third.present? }
    retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      PostProcessingJob.perform_now(@download.id)
    end

    @request.reload
    assert @request.processing?
    assert_nil @request.issue_description
    assert_equal retry_job.arguments.third, @download.reload.post_processing_job_id
  end

  test "copies when source path appears on a later retry" do
    FileUtils.rm_rf(@temp_source)
    SettingsService.set(:audiobookshelf_url, "")

    retry_args = ->(args) { args.first(2) == [ @download.id, 1 ] && args.third.present? }
    retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      PostProcessingJob.perform_now(@download.id)
    end

    FileUtils.mkdir_p(@temp_source)
    File.write(File.join(@temp_source, "audiobook.mp3"), "test audio content")
    retry_job.perform_now

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    assert @request.reload.completed?
    assert File.exist?(File.join(expected_dest, "audiobook.mp3"))
  end

  test "duplicate retry chains import an ebook only once" do
    FileUtils.rm_rf(@temp_source)
    @book.update!(book_type: :ebook)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:post_processing_source_path_retries, 2)
    SettingsService.set(:audiobookshelf_ebook_library_id, "ebook-library")
    completed_notifications = []
    library_scans = []

    LibraryPlatformClient.stub(:configured?, true) do
      LibraryPlatformClient.stub(:scan_library, ->(library_id) { library_scans << library_id }) do
        NotificationService.stub(:request_completed, ->(request) { completed_notifications << request.id }) do
          3.times { PostProcessingJob.perform_now(@download.id) }

          retry_jobs = enqueued_jobs.select { |job| job[:job] == PostProcessingJob }
          waiting_events = @request.request_events.where(event_type: "post_processing_waiting", download_id: @download.id)

          assert_equal 1, retry_jobs.count
          assert_equal 1, waiting_events.count

          retry_args = ->(args) { args.first(2) == [ @download.id, 1 ] && args.third.present? }
          retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args)
          assert_equal retry_job.arguments.third, @download.reload.post_processing_job_id

          FileUtils.mkdir_p(@temp_source)
          write_valid_ebook_file(File.join(@temp_source, "Original.epub"))
          retry_job.perform_now

          2.times { PostProcessingJob.perform_now(@download.id, 1) }
        end
      end
    end

    imported_files = Dir.glob(File.join(@temp_dest_base, "**", "*.epub"))

    assert_equal [ "Test Author - Test Audiobook.epub" ], imported_files.map { |path| File.basename(path) }
    assert_equal [ @request.id ], completed_notifications
    assert_equal [ "ebook-library" ], library_scans
    assert @request.reload.completed?
  end

  test "post-processing ownership is stable for one job and rejects another" do
    owner = PostProcessingJob.new(@download.id)
    duplicate = PostProcessingJob.new(@download.id)

    assert @download.claim_post_processing!(owner.job_id)
    assert @download.claim_post_processing!(owner.job_id)
    assert_not @download.claim_post_processing!(duplicate.job_id)
    assert_equal owner.job_id, @download.reload.post_processing_job_id

    assert duplicate.job_id.present?
    assert @download.claim_post_processing!(duplicate.job_id, expected_owner_job_id: owner.job_id)
    assert_equal duplicate.job_id, @download.reload.post_processing_job_id
  end

  test "duplicate delivery of one job cannot import concurrently" do
    SettingsService.set(:audiobookshelf_url, "")
    original_job = PostProcessingJob.new(@download.id)
    duplicate_job = PostProcessingJob.deserialize(original_job.serialize)
    real_copy = FileCopyService.method(:copy_source_io)
    entered_copy = Queue.new
    release_copy = Queue.new
    paused = false
    errors = Queue.new
    first = nil
    duplicate = nil

    pausing_copy = lambda do |source, target, heartbeat: nil|
      unless paused
        paused = true
        entered_copy << true
        release_copy.pop
      end
      real_copy.call(source, target, heartbeat: heartbeat)
    end

    FileCopyService.stub(:copy_source_io, pausing_copy) do
      first = Thread.new do
        original_job.perform_now
      rescue => error
        errors << error
      end
      entered_copy.pop
      duplicate = Thread.new do
        duplicate_job.perform_now
      rescue => error
        errors << error
      end

      sleep 0.05
      assert duplicate.alive?
      release_copy << true
      first.join
      duplicate.join
    end

    expected_directory = File.join(@temp_dest_base, @book.author, @book.title)
    flunk errors.pop.full_message unless errors.empty?
    assert @request.reload.completed?
    assert_equal [ "audiobook.mp3" ], Dir.children(expected_directory)
  ensure
    release_copy << true if release_copy && first&.alive?
    first&.join
    duplicate&.join
  end

  test "scheduled retry owns durable recovery and blocks cancellation" do
    FileUtils.rm_rf(@temp_source)
    SettingsService.set(:audiobookshelf_url, "")

    retry_args = ->(args) { args.first(2) == [ @download.id, 1 ] && args.third.present? }
    retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      PostProcessingJob.perform_now(@download.id)
    end

    error = assert_raises(Request::CancellationBlockedError) { @request.cancel! }
    FileUtils.mkdir_p(@temp_source)
    File.write(File.join(@temp_source, "audiobook.mp3"), "test audio content")
    retry_job.perform_now

    expected_file = File.join(@temp_dest_base, @book.author, @book.title, "audiobook.mp3")
    assert_match(/post-processing recovery/i, error.message)
    assert @request.reload.completed?
    assert File.exist?(expected_file)
  end

  test "cancellation cannot interleave after post-processing claims the request" do
    SettingsService.set(:audiobookshelf_url, "")
    job = PostProcessingJob.new(@download.id)
    real_import = job.method(:import_files)
    cancellation_error = nil

    job.stub(:import_files, ->(*args, **kwargs) {
      cancellation_error = assert_raises(Request::CancellationBlockedError) do
        @request.reload.cancel!
      end
      real_import.call(*args, **kwargs)
    }) do
      job.perform_now
    end

    assert_match(/post-processing recovery/i, cancellation_error.message)
    assert @request.reload.completed?
    assert_nil @download.reload.post_processing_job_id
  end

  test "a hard kill during atomic finalization retains owner and retries idempotently" do
    SettingsService.set(:audiobookshelf_url, "")
    first_job = PostProcessingJob.new(@download.id)
    real_track = ActivityTracker.method(:track)
    kill_during_completion = lambda do |action, **options|
      raise Interrupt, "simulated hard kill" if action == "request.completed"

      real_track.call(action, **options)
    end

    ActivityTracker.stub(:track, kill_during_completion) do
      assert_raises(Interrupt) { first_job.perform_now }
    end

    imported_file = File.join(
      @temp_dest_base,
      @book.author,
      @book.title,
      "audiobook.mp3"
    )
    assert File.exist?(imported_file)
    assert_nil @book.reload.file_path
    assert @request.reload.processing?
    assert_equal first_job.job_id, @download.reload.post_processing_job_id

    retry_job = PostProcessingJob.new(@download.id, 0, first_job.job_id)
    retry_job.perform_now

    assert_equal imported_file.sub(%r{/audiobook\.mp3\z}, ""), @book.reload.file_path
    assert @request.reload.completed?
    assert_nil @download.reload.post_processing_job_id
    assert_equal "test audio content", File.binread(imported_file)
  end

  test "recovers a legacy crash after Book path attachment but before Request completion" do
    SettingsService.set(:audiobookshelf_url, "")
    imported_path = File.join(@temp_dest_base, "legacy-import.m4b")
    File.binwrite(imported_path, "legacy imported bytes")
    @book.update!(file_path: imported_path)
    @request.update!(status: :processing)
    @download.update!(post_processing_job_id: "legacy-post-processing-owner")
    retry_job = PostProcessingJob.new(
      @download.id,
      0,
      "legacy-post-processing-owner"
    )

    retry_job.perform_now

    assert @request.reload.completed?
    assert_nil @download.reload.post_processing_job_id
    assert_equal imported_path, @book.reload.file_path
    assert_equal "legacy imported bytes", File.binread(imported_path)
    assert File.exist?(@temp_source), "legacy recovery must not remove an unverified source"
  end

  test "a late completion-side-effect failure cannot reopen a completed request" do
    SettingsService.set(:audiobookshelf_url, "")
    job = PostProcessingJob.new(@download.id)

    job.stub(:run_completion_side_effects, ->(*) { raise IOError, "late failure" }) do
      job.perform_now
    end

    assert @request.reload.completed?
    assert_not @request.attention_needed?
    assert_nil @download.reload.post_processing_job_id
    assert @book.reload.file_path.present?
  end

  test "logs and attention state do not expose titles paths raw errors or backtraces" do
    secret_title = "PRIVATE TITLE #{SecureRandom.hex(8)}"
    secret_path = "/private/library/#{SecureRandom.hex(8)}/#{secret_title}"
    @book.update!(title: secret_title)
    @download.update!(download_path: secret_path)
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:post_processing_source_path_retries, 0)

    output = capture_private_post_processing_logs do
      PostProcessingJob.perform_now(@download.id)
    end

    issue = @request.reload.issue_description
    assert_includes output, "Download ##{@download.id} failed: RuntimeError"
    refute_includes output, secret_title
    refute_includes output, secret_path
    refute_includes output, "post_processing_job.rb:"
    refute_includes issue, secret_title
    refute_includes issue, secret_path
    assert_match(/source path not found/i, issue)
  end

  test "debug SQL around successful finalization does not expose library path binds" do
    secret_title = "PRIVATE BIND TITLE #{SecureRandom.hex(8)}"
    secret_root = File.join(@temp_dest_base, "private-bind-#{SecureRandom.hex(8)}")
    FileUtils.mkdir_p(secret_root)
    @book.update!(title: secret_title)
    SettingsService.set(:audiobook_output_path, secret_root)
    SettingsService.set(:audiobookshelf_url, "")

    output = capture_private_post_processing_logs do
      NotificationService.stub(:request_completed, true) do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    assert @request.reload.completed?
    refute_includes output, secret_title
    refute_includes output, secret_root
    refute_match(/Book Update.*file_path/i, output)
  end

  test "marks request for attention when source path is blank" do
    @download.update!(download_path: "")

    PostProcessingJob.perform_now(@download.id)
    @request.reload

    assert @request.attention_needed?
    assert_match /source path is blank/i, @request.issue_description
  end

  test "sends attention notification when post-processing fails" do
    @download.update!(download_path: "")
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      PostProcessingJob.perform_now(@download.id)
    end

    assert_equal [ @request ], attention_requests
  end

  test "marks request for attention when source path does not exist" do
    @download.update!(download_path: "/nonexistent/path/that/does/not/exist")
    SettingsService.set(:post_processing_source_path_retries, 1)

    PostProcessingJob.perform_now(@download.id, 1)

    @request.reload

    assert @request.attention_needed?
    assert_match /source path not found/i, @request.issue_description
  end

  test "imports supported ebook files and skips unsupported files in the directory" do
    FileUtils.rm_rf(@temp_source)
    nested_source = File.join(@temp_source, "Nested")
    FileUtils.mkdir_p(nested_source)
    write_valid_ebook_file(File.join(@temp_source, "Valid Book.epub"))
    File.write(File.join(nested_source, "alternate.rtf"), "unsupported alternate format")

    @book.update!(book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    @request.reload
    assert @request.completed?
    assert_not @request.attention_needed?
    assert File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.epub"))
    assert_not File.exist?(File.join(expected_dest, "alternate.rtf"))
  end

  test "marks ebook directory import for attention when it has no supported ebook files" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    File.write(File.join(@temp_source, "alternate.rtf"), "unsupported alternate format")

    @book.update!(book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    @request.reload
    assert @request.attention_needed?
    assert_match /no supported ebook files found/i, @request.issue_description
    assert_not File.exist?(File.join(expected_dest, "alternate.rtf"))
  end

  test "marks single file ebook import for attention when extension is unsupported" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    source_file = File.join(@temp_source, "payload.exe")
    File.write(source_file, "bad executable content")

    @book.update!(book_type: :ebook)
    @download.update!(download_path: source_file)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    @request.reload
    assert @request.attention_needed?
    assert_match /unsupported ebook import file type/i, @request.issue_description
    assert_not File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.exe"))
  end

  test "marks ebook import for attention when allowed ebook extension has invalid content" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    source_file = File.join(@temp_source, "payload.epub")
    File.binwrite(source_file, "MZ bad executable content")

    @book.update!(book_type: :ebook)
    @download.update!(download_path: source_file)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    @request.reload
    assert @request.attention_needed?
    assert_match /unsupported ebook import file type/i, @request.issue_description
    assert_not File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.epub"))
  end

  test "marks ebook directory import for attention when image sidecar has invalid content" do
    FileUtils.rm_rf(@temp_source)
    FileUtils.mkdir_p(@temp_source)
    write_valid_ebook_file(File.join(@temp_source, "Valid Book.epub"))
    File.binwrite(File.join(@temp_source, "cover.jpg"), "MZ bad executable content")

    @book.update!(book_type: :ebook)
    SettingsService.set(:ebook_output_path, @temp_dest_base)
    SettingsService.set(:audiobookshelf_url, "")

    PostProcessingJob.perform_now(@download.id)

    expected_dest = File.join(@temp_dest_base, @book.author, @book.title)
    @request.reload
    assert @request.attention_needed?
    assert_match /unsupported ebook import file type/i, @request.issue_description
    assert_not File.exist?(File.join(expected_dest, "cover.jpg"))
    assert_not File.exist?(File.join(expected_dest, "Test Author - Test Audiobook.epub"))
  end

  private

  def capture_private_post_processing_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    original_active_record_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger

    Rails.stub(:logger, logger) { yield }
    output.string
  ensure
    ActiveRecord::Base.logger = original_active_record_logger
  end

  def write_valid_ebook_file(path)
    case File.extname(path).delete_prefix(".").downcase
    when "epub", "cbz"
      File.binwrite(path, "PK\x03\x04valid ebook content")
    when "mobi", "azw", "azw3"
      File.binwrite(path, ("\0" * 60) + "BOOKMOBI")
    when "pdf"
      File.binwrite(path, "%PDF-1.7\n")
    when "djvu"
      File.binwrite(path, "AT&TFORM\0\0\0\0DJVM")
    else
      raise "Unsupported test ebook extension: #{path}"
    end
  end

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
