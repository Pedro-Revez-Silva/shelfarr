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

  test "targeted upload completes the existing request" do
    request = requests(:pending_request)
    ebook_file = File.join(@temp_source, "Archived Ebook.epub")
    File.write(ebook_file, "test ebook content")
    download = request.downloads.create!(name: "Previous download", status: :queued)
    paused_download = request.downloads.create!(name: "Paused download", status: :paused)

    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: "Archived Ebook.epub",
      file_path: ebook_file,
      file_size: 100,
      status: :pending
    )

    assert_no_difference "Book.count" do
      UploadProcessingJob.perform_now(upload.id)
    end

    upload.reload
    request.reload

    assert upload.completed?
    assert_equal request.book, upload.book
    assert request.completed?
    assert request.completed_at.present?
    assert_not request.attention_needed?
    assert download.reload.failed?
    assert paused_download.reload.failed?
    assert_equal File.join(@temp_ebook_dest, request.book.author, request.book.title), request.book.file_path
    assert request.request_events.exists?(event_type: "upload_fulfilled")
  end

  test "targeted audiobook zip upload extracts files into library" do
    request = requests(:failed_request)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(
      zip_file,
      "chapter_01.mp3" => "audio-one",
      "disc_02/chapter_02.mp3" => "audio-two"
    )

    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: "Third Author - The Failed Audiobook.zip",
      file_path: zip_file,
      file_size: File.size(zip_file),
      status: :pending
    )

    UploadProcessingJob.perform_now(upload.id)

    upload.reload
    request.reload

    expected_path = File.join(@temp_audiobook_dest, "Third Author", "The Failed Audiobook")

    assert upload.completed?
    assert request.completed?
    assert_equal expected_path, request.book.reload.file_path
    assert File.exist?(File.join(expected_path, "chapter_01.mp3"))
    assert File.exist?(File.join(expected_path, "disc_02", "chapter_02.mp3"))
    assert_not File.exist?(File.join(expected_path, "Third Author - The Failed Audiobook.zip"))
    assert_not File.exist?(zip_file)
  end

  test "targeted audiobook zip upload rejects unsafe archive paths" do
    request = requests(:failed_request)
    zip_file = File.join(@temp_source, "Unsafe Audiobook.zip")
    build_zip_archive(zip_file, "../escape.mp3" => "audio")

    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: "Unsafe Audiobook.zip",
      file_path: zip_file,
      file_size: File.size(zip_file),
      status: :pending
    )

    UploadProcessingJob.perform_now(upload.id)

    upload.reload
    request.reload

    assert upload.failed?
    assert_includes upload.error_message, "unsafe path"
    assert request.failed?
    assert_nil request.book.reload.file_path
    assert File.exist?(zip_file)
    assert_not File.exist?(File.join(@temp_audiobook_dest, "Third Author", "escape.mp3"))
  end

  test "audiobook zip extraction rejects archives over extracted size limit" do
    zip_file = File.join(@temp_source, "Oversized Audiobook.zip")
    destination = File.join(@temp_audiobook_dest, "Oversized")
    build_zip_archive(zip_file, "chapter_01.mp3" => "audio-data")

    error = assert_raises(RuntimeError) do
      UploadProcessingJob.new.send(:extract_zip_upload_to_directory, zip_file, destination, max_bytes: 5)
    end

    assert_includes error.message, "extracted size limit"
    assert_not File.exist?(File.join(destination, "chapter_01.mp3"))
  end

  test "audiobook zip extraction rejects archives with too many files" do
    zip_file = File.join(@temp_source, "Too Many Files.zip")
    destination = File.join(@temp_audiobook_dest, "Too Many Files")
    build_zip_archive(
      zip_file,
      "chapter_01.mp3" => "audio-one",
      "chapter_02.mp3" => "audio-two"
    )

    error = assert_raises(RuntimeError) do
      UploadProcessingJob.new.send(:extract_zip_upload_to_directory, zip_file, destination, max_files: 1)
    end

    assert_includes error.message, "too many files"
    assert_not File.exist?(File.join(destination, "chapter_01.mp3"))
    assert_not File.exist?(File.join(destination, "chapter_02.mp3"))
  end

  test "audiobook zip extraction rejects files that would overwrite existing library files" do
    zip_file = File.join(@temp_source, "Existing File.zip")
    destination = File.join(@temp_audiobook_dest, "Existing File")
    existing_file = File.join(destination, "chapter_01.mp3")
    FileUtils.mkdir_p(destination)
    File.write(existing_file, "existing-audio")
    build_zip_archive(
      zip_file,
      "chapter_02.mp3" => "new-audio",
      "chapter_01.mp3" => "replacement-audio"
    )

    error = assert_raises(RuntimeError) do
      UploadProcessingJob.new.send(:extract_zip_upload_to_directory, zip_file, destination)
    end

    assert_includes error.message, "overwrite an existing file"
    assert_equal "existing-audio", File.read(existing_file)
    assert_not File.exist?(File.join(destination, "chapter_02.mp3"))
  end

  test "targeted upload fails if request completed before processing" do
    request = requests(:pending_request)
    ebook_file = File.join(@temp_source, "Late Ebook.epub")
    File.write(ebook_file, "test ebook content")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: "Late Ebook.epub",
      file_path: ebook_file,
      file_size: 100,
      status: :pending
    )
    request.complete!

    UploadProcessingJob.perform_now(upload.id)

    upload.reload
    assert upload.failed?
    assert_equal "Request is already completed", upload.error_message
    assert_nil upload.book
    assert_nil request.book.reload.file_path
    assert File.exist?(ebook_file)
  end

  test "targeted upload fails if request is already being completed" do
    request = requests(:pending_request)
    ebook_file = File.join(@temp_source, "Already Processing.epub")
    File.write(ebook_file, "test ebook content")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: "Already Processing.epub",
      file_path: ebook_file,
      file_size: 100,
      status: :pending
    )
    request.update!(status: :processing)

    UploadProcessingJob.perform_now(upload.id)

    upload.reload
    assert upload.failed?
    assert_equal "Request is already being completed", upload.error_message
    assert_nil upload.book
    assert_nil request.book.reload.file_path
    assert File.exist?(ebook_file)
  end

  test "backfills existing matched book with metadata when needed" do
    original_source = SettingsService.get(:metadata_source)
    original_token = SettingsService.get(:hardcover_api_token)

    SettingsService.set(:metadata_source, "hardcover")
    SettingsService.set(:hardcover_api_token, "test_token")
    HardcoverClient.reset_connection!

    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    VCR.turned_off do
      stub_hardcover_upload_metadata_search(
        query: "Mistborn Brandon Sanderson",
        id: 12345,
        series_position: "3"
      )

      UploadProcessingJob.perform_now(@upload.id)
    end

    @upload.reload
    existing.reload

    assert_equal existing, @upload.book
    assert_equal "3", existing.series_position
  ensure
    SettingsService.set(:metadata_source, original_source)
    SettingsService.set(:hardcover_api_token, original_token || "")
    HardcoverClient.reset_connection!
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

  test "uses extracted metadata when available" do
    extracted = MetadataExtractorService::Result.new(
      title: "Extracted Title",
      author: "Extracted Author",
      year: 2024,
      description: "Embedded description",
      narrator: "Narrator",
      success: true
    )

    MetadataExtractorService.stub(:extract, extracted) do
      VCR.turned_off do
        stub_open_library_search("Extracted Title Extracted Author")

        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    assert_equal "Extracted Title", @upload.reload.parsed_title
    assert_equal 90, @upload.match_confidence
  end

  test "fetch_metadata returns nil for blank title and service errors" do
    job = UploadProcessingJob.new

    assert_nil job.send(:fetch_metadata, "", "Author")

    MetadataService.stub(:search, ->(*) { raise MetadataService::Error, "offline" }) do
      assert_nil job.send(:fetch_metadata, "Title", "Author")
    end
  end

  test "fetch_metadata returns best reasonable metadata match" do
    job = UploadProcessingJob.new
    weak = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_WEAK",
      title: "Different",
      author: "Other",
      description: nil,
      year: nil,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )
    strong = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_STRONG",
      title: "Mistborn",
      author: "Brandon Sanderson",
      description: nil,
      year: nil,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:search, [ weak, strong ]) do
      assert_equal strong, job.send(:fetch_metadata, "Mistborn", "Brandon Sanderson")
    end
  end

  test "score_result handles exact title author bonus and blank values" do
    job = UploadProcessingJob.new
    result = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_SCORE",
      title: "Mistborn",
      author: "Brandon Sanderson",
      description: nil,
      year: nil,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    assert_operator job.send(:score_result, result, "Mistborn", "Brandon Sanderson"), :>=, 90
    assert_operator job.send(:score_result, result, "Mistborn", nil), :>=, 60
    assert_equal 0, job.send(:string_similarity, "", "Mistborn")
  end

  test "handle_duplicate_filename increments existing path" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Book.epub")
      File.write(path, "one")
      File.write(File.join(dir, "Book (2).epub"), "two")

      assert_equal File.join(dir, "Book (3).epub"), UploadProcessingJob.new.send(:handle_duplicate_filename, path)
    end
  end

  test "move_to_library copies across filesystems when rename fails" do
    book = Book.create!(title: "Copy Book", author: "Copy Author", book_type: :audiobook)
    destination = File.join(@temp_audiobook_dest, "Copy Author", "Copy Book")
    expected_file = File.join(destination, "Copy Author - Copy Book.m4b")

    FileUtils.stub(:mv, ->(*) { raise Errno::EXDEV }) do
      UploadProcessingJob.new.send(:move_to_library, @upload, book)
    end

    assert File.exist?(expected_file)
    assert_not File.exist?(@test_file)
  end

  test "trigger_library_scan uses configured library and swallows client errors" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "audio-lib")
    book = books(:audiobook_acquired)
    scanned = []

    LibraryPlatformClient.stub(:scan_library, ->(library_id) { scanned << library_id }) do
      UploadProcessingJob.new.send(:trigger_library_scan, book)
    end

    assert_equal [ "audio-lib" ], scanned

    LibraryPlatformClient.stub(:scan_library, ->(*) { raise LibraryPlatformClient::Error, "scan failed" }) do
      assert_nothing_raised { UploadProcessingJob.new.send(:trigger_library_scan, book) }
    end
  end

  private

  def stub_open_library_search(query)
    stub_request(:get, %r{https://www\.googleapis\.com/books/v1/volumes})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { items: [] }.to_json
      )

    # Stub Open Library search to return empty results
    # This allows tests to focus on file operations and book creation
    stub_request(:get, %r{https://openlibrary\.org/search\.json})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { numFound: 0, docs: [] }.to_json
      )
  end

  def build_zip_archive(path, entries)
    require "zip"

    Zip::File.open(path, create: true) do |zipfile|
      entries.each do |name, content|
        zipfile.get_output_stream(name) { |stream| stream.write(content) }
      end
    end
  end

  def stub_hardcover_upload_metadata_search(query:, id:, series_position:)
    search_body = {
      data: {
        search: {
          results: {
            hits: [
              {
                document: {
                  id: id,
                  title: "Mistborn",
                  author_names: [ "Brandon Sanderson" ],
                  release_year: 2006,
                  cached_image: "https://example.com/cover.jpg",
                  has_audiobook: true,
                  has_ebook: true
                }
              }
            ]
          }
        }
      }
    }

    book_body = {
      data: {
        books: [
          {
            id: id,
            title: "Mistborn",
            description: "Epic fantasy series.",
            release_year: 2006,
            cached_image: "https://example.com/cover.jpg",
            contributions: [ { author: { name: "Brandon Sanderson" } } ],
            default_physical_edition: nil,
            book_series: [],
            featured_book_series: [
              {
                position: series_position,
                series: { name: "Mistborn" }
              }
            ]
          }
        ]
      }
    }

    headers = { "Content-Type" => "application/json" }

    stub_request(:post, HardcoverClient::BASE_URL)
      .with { |req| req.body.include?(query) && req.body.include?("query SearchBooks") }
      .to_return(status: 200, headers: headers, body: search_body.to_json)
    stub_request(:post, HardcoverClient::BASE_URL)
      .with { |req| req.body.include?("query GetBook") }
      .to_return(status: 200, headers: headers, body: book_body.to_json)
  end
end
