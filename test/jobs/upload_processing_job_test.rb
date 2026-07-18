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

  test "resumes an ordinary upload published just before a worker was killed" do
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    @upload.update!(status: :processing, file_size: File.size(@test_file))
    file_service = UploadImportFileService.new(upload: @upload, book: existing)
    file_service.reserve!
    expected_library_path = file_service.publish!
    destination = @upload.reload.destination_path

    assert File.exist?(@test_file), "publication preserves the source until database completion"
    assert_equal "test audio content", File.binread(destination)

    # The stale watchdog performs this single state transition before the
    # replacement job begins.
    @upload.update!(status: :pending)
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      UploadProcessingJob.perform_now(@upload.id)
    end

    assert @upload.reload.completed?
    assert_equal existing, @upload.book
    assert_equal expected_library_path, existing.reload.file_path
    assert_equal file_service.display_destination_path, @upload.file_path
    assert_nil @upload.cleanup_source_path
    assert_equal 0, File.size(@test_file)
    assert_equal "test audio content", File.binread(destination)
  end

  test "durably retries completed source cleanup after an immediate cleanup failure" do
    source_path = File.realpath(@test_file)

    UploadImportFileService.stub(:cleanup_completed_source!, false) do
      VCR.turned_off do
        stub_open_library_search("Mistborn Brandon Sanderson")
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    assert @upload.reload.completed?
    assert_equal source_path, @upload.cleanup_source_path
    assert File.exist?(source_path)
    assert_equal @upload.destination_path, File.realpath(@upload.file_path)

    UploadRecoveryJob.perform_now

    assert_nil @upload.reload.cleanup_source_path
    assert_equal 0, File.size(source_path)
    assert File.exist?(@upload.file_path)
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

  test "find_or_create_book_with_metadata defaults comicbook uploads to graphic content kind" do
    parsed = Struct.new(:title, :author).new("Saga #1", "Brian K. Vaughan")

    book = UploadProcessingJob.new.send(
      :find_or_create_book_with_metadata,
      metadata: nil,
      extracted: nil,
      parsed: parsed,
      book_type: "comicbook"
    )

    assert book.comicbook?
    assert book.content_graphic?
  end

  test "find_or_create_book_with_metadata normalizes legacy and unknown content kinds" do
    metadata_class = Struct.new(
      :title, :author, :work_id, :cover_url, :year, :description, :content_kind,
      keyword_init: true
    )
    legacy_metadata = metadata_class.new(title: "Legacy Manga", author: "Creator", content_kind: "manga")
    unknown_metadata = metadata_class.new(title: "Unknown Kind", author: "Author", content_kind: "periodical")

    legacy_book = UploadProcessingJob.new.send(
      :find_or_create_book_with_metadata,
      metadata: legacy_metadata,
      extracted: nil,
      parsed: legacy_metadata,
      book_type: "comicbook"
    )
    unknown_book = UploadProcessingJob.new.send(
      :find_or_create_book_with_metadata,
      metadata: unknown_metadata,
      extracted: nil,
      parsed: unknown_metadata,
      book_type: "ebook"
    )

    assert legacy_book.content_graphic?
    assert unknown_book.content_book?
  end

  test "richer metadata remains ahead of the owned-catalog fallback" do
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0PRIORITY1",
      title: "Owned Fallback Title",
      authors: [ "Owned Fallback Author" ],
      narrators: [ "Owned Fallback Narrator" ],
      cover_url: "https://m.media-amazon.com/images/I/owned-fallback.jpg"
    )
    metadata_class = Struct.new(
      :title, :author, :work_id, :cover_url, :year, :description, :content_kind,
      keyword_init: true
    )
    metadata = metadata_class.new(
      title: "Online Title",
      author: "Online Author",
      cover_url: "https://covers.example.test/online.jpg"
    )
    extracted = MetadataExtractorService::Result.new(
      title: "Embedded Title",
      author: "Embedded Author",
      year: nil,
      description: nil,
      narrator: "Embedded Narrator",
      success: true
    )
    parsed = Struct.new(:title, :author).new("Filename Title", "Filename Author")

    book = UploadProcessingJob.new.send(
      :find_or_create_book_with_metadata,
      metadata: metadata,
      extracted: extracted,
      parsed: parsed,
      book_type: "audiobook",
      owned_item: item,
      force_new: true
    )

    assert_equal "Online Title", book.title
    assert_equal "Online Author", book.author
    assert_equal "Embedded Narrator", book.narrator
    assert_equal "https://covers.example.test/online.jpg", book.cover_url
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
      assert_nil @upload.book_reservation_token
      assert_nil existing.reload.acquisition_reservation_token
    end
  end

  test "reserves the Book durably before ordinary publication and finalizes outside a long transaction" do
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    original_new = UploadImportFileService.method(:new)
    observed = false
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    factory = lambda do |**arguments|
      service = original_new.call(**arguments)
      original_publish = service.method(:publish!)
      service.define_singleton_method(:publish!) do
        current_upload = arguments.fetch(:upload).reload
        current_book = arguments.fetch(:book).reload
        observed = current_upload.book_reservation_token.present? &&
          current_book.acquisition_reservation_token == current_upload.book_reservation_token &&
          current_book.acquisition_reservation_owner_type == "Upload" &&
          current_book.acquisition_reservation_owner_id == current_upload.id &&
          ActiveRecord::Base.connection.open_transactions == baseline_transactions
        original_publish.call
      end
      service
    end

    UploadImportFileService.stub(:new, factory) do
      VCR.turned_off do
        stub_open_library_search("Mistborn Brandon Sanderson")
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    assert observed
    assert @upload.reload.completed?
    assert_equal existing, @upload.book
    assert_nil @upload.book_reservation_token
    assert_nil existing.reload.acquisition_reservation_token
  end

  test "a direct-download Book reservation blocks upload publication without disturbing either source" do
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook,
      acquisition_reservation_token: "direct-owner-token",
      acquisition_reservation_owner_type: "Download",
      acquisition_reservation_owner_id: 88_001
    )

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      UploadProcessingJob.perform_now(@upload.id)
    end

    assert @upload.reload.failed?
    assert_match(/Another acquisition already claimed/, @upload.error_message)
    assert_nil @upload.destination_path
    assert_nil @upload.book_reservation_token
    assert_nil @upload.book_id
    assert_equal "test audio content", File.binread(@test_file)
    assert_equal "direct-owner-token", existing.reload.acquisition_reservation_token
    assert_equal "Download", existing.acquisition_reservation_owner_type
  end

  test "ordinary Book CAS failure removes only its verified publication and releases its reservation" do
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    published_destination = nil
    original_claim = UploadProcessingJob.instance_method(:claim_book_file_path!)
    conflicting_job = UploadProcessingJob.new
    conflicting_job.define_singleton_method(:claim_book_file_path!) do |book, destination, current_upload|
      published_destination = current_upload.reload.destination_path
      book.update_columns(file_path: "/library/a-competing-copy")
      original_claim.bind_call(self, book, destination, current_upload)
    end

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      conflicting_job.perform(@upload.id)
    end

    assert @upload.reload.failed?
    assert_not File.exist?(published_destination)
    assert_equal "test audio content", File.binread(@test_file)
    assert_nil @upload.destination_path
    assert_nil @upload.book_reservation_token
    assert_nil @upload.book_id
    assert_nil existing.reload.file_path
    assert_nil existing.acquisition_reservation_token

    @upload.update!(status: :pending, error_message: nil)
    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      UploadProcessingJob.perform_now(@upload.id)
    end
    assert @upload.reload.completed?
    assert_equal existing, @upload.book
  end

  test "refuses to replace an existing acquired book file" do
    existing_directory = File.join(@temp_audiobook_dest, "Brandon Sanderson", "Mistborn")
    existing_file = File.join(existing_directory, "Brandon Sanderson - Mistborn.m4b")
    FileUtils.mkdir_p(existing_directory)
    File.binwrite(existing_file, "original library audio")
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook,
      file_path: existing_directory
    )

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      UploadProcessingJob.perform_now(@upload.id)
    end

    assert @upload.reload.failed?
    assert_match(/existing file was preserved/, @upload.error_message)
    assert_equal existing_directory, existing.reload.file_path
    assert_equal "original library audio", File.binread(existing_file)
    assert File.exist?(@test_file)
    assert_nil @upload.destination_path
    assert_nil @upload.library_path
  end

  test "an explicit Audible separate-edition backup creates a distinct canonical path" do
    existing_directory = File.join(@temp_audiobook_dest, "Brandon Sanderson", "Mistborn")
    existing_file = File.join(existing_directory, "Brandon Sanderson - Mistborn.m4b")
    FileUtils.mkdir_p(existing_directory)
    File.binwrite(existing_file, "original library audio")
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook,
      file_path: existing_directory
    )
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Mistborn",
      authors: [ "Brandon Sanderson" ],
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing",
      separate_edition: true
    )

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      assert_difference -> { Book.count }, 1 do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    imported = @upload.reload.book
    assert @upload.completed?
    assert_not_equal existing, imported
    assert_equal existing_directory, existing.reload.file_path
    assert_equal "original library audio", File.binread(existing_file)
    expected_import_directory = "#{File.realpath(existing_directory)} (2)"
    assert_equal expected_import_directory, imported.file_path
    assert File.exist?(File.join(imported.file_path, "Brandon Sanderson - Mistborn.m4b"))
  end

  test "Audible import falls back to its trusted owned-catalog metadata" do
    @upload.update!(
      original_filename: "opaque-backup.m4b",
      file_size: File.size(@test_file)
    )
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0METADATA1",
      title: "Authoritative Audible Title",
      subtitle: "Audible Edition",
      authors: [ "Authoritative Author" ],
      narrators: [ "Authoritative Narrator" ],
      cover_url: "https://m.media-amazon.com/images/I/authoritative-cover.jpg",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )

    MetadataExtractorService.stub(:extract, MetadataExtractorService::Result.empty) do
      MetadataService.stub(:search, []) do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    book = @upload.reload.book
    assert @upload.completed?
    assert_equal "Authoritative Audible Title: Audible Edition", book.title
    assert_equal "Authoritative Author", book.author
    assert_equal "Authoritative Narrator", book.narrator
    assert_equal "https://m.media-amazon.com/images/I/authoritative-cover.jpg", book.cover_url
  end

  test "resumes an Audible import finalized just before a worker was killed" do
    book = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    @upload.update!(book: book, file_size: File.size(@test_file))
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0CRASHSAFE",
      title: book.title,
      authors: [ book.author ],
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )
    OwnedMediaImportFileService.ensure_persistent_staging!(media_import, @upload)
    @upload.reload
    service = OwnedMediaImportFileService.new(
      media_import: media_import,
      upload: @upload,
      book: book
    )

    # This is the hard-exit window: the final file exists, the staged file is
    # gone, and the database transaction which records completion never ran.
    service.with_destination_lock { service.finalize! }
    destination = media_import.reload.destination_path
    assert_not File.exist?(@upload.file_path)
    assert File.exist?(destination)

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      assert_no_difference -> { Book.count } do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    assert @upload.reload.completed?
    assert_equal book, @upload.book
    assert_equal File.dirname(destination), book.reload.file_path
    assert_equal "test audio content", File.binread(destination)
  end

  test "restores a destination-only Audible file when metadata processing fails early" do
    book = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    @upload.update!(book: book, file_size: File.size(@test_file))
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0EARLYFAIL",
      title: book.title,
      authors: [ book.author ],
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )
    OwnedMediaImportFileService.ensure_persistent_staging!(media_import, @upload)
    @upload.reload
    staged_path = @upload.file_path
    service = OwnedMediaImportFileService.new(
      media_import: media_import,
      upload: @upload,
      book: book
    )
    service.with_destination_lock { service.finalize! }
    destination = media_import.reload.destination_path
    library_path = media_import.library_path

    MetadataExtractorService.stub(:extract, ->(*) { raise IOError, "metadata reader failed" }) do
      UploadProcessingJob.perform_now(@upload.id)
    end

    assert @upload.reload.failed?
    assert media_import.reload.failed?
    assert File.exist?(staged_path)
    assert_equal "test audio content", File.binread(staged_path)
    assert File.exist?(destination)
    assert File.exist?(library_path)
    assert_equal "test audio content", File.binread(destination)
    assert_equal destination, media_import.destination_path
    assert_equal library_path, media_import.library_path
    assert media_import.staged_device.present?
    assert media_import.staged_inode.present?
  end

  test "Audible processing logs identifiers without title author or artifact path" do
    secret_title = "Private Purchased Title #{SecureRandom.hex(4)}"
    secret_author = "Private Author #{SecureRandom.hex(4)}"
    secret_directory = Dir.mktmpdir("private-audible-artifact")
    secret_path = File.join(secret_directory, "private-owned-copy.m4b")
    File.binwrite(secret_path, "private audible bytes")
    book = Book.create!(title: secret_title, author: secret_author, book_type: :audiobook)
    @upload.update!(
      book: book,
      original_filename: "#{secret_author} - #{secret_title}.m4b",
      file_path: secret_path,
      file_size: File.size(secret_path)
    )
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0PRIVATE#{SecureRandom.hex(3).upcase}",
      title: secret_title,
      authors: [ secret_author ],
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )

    logs = capture_upload_job_logs do
      MetadataService.stub(:search, []) do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end.join("\n")

    assert @upload.reload.completed?
    assert_includes logs, "upload ##{@upload.id}"
    assert_includes logs, "book ##{book.id}"
    assert_not_includes logs, secret_title
    assert_not_includes logs, secret_author
    assert_not_includes logs, secret_path
  ensure
    FileUtils.rm_rf(secret_directory) if secret_directory
  end

  test "Audible failures keep bounded user diagnostics out of application logs" do
    secret_title = "Unlogged Audible Title #{SecureRandom.hex(4)}"
    secret_directory = Dir.mktmpdir("unlogged-audible-path")
    secret_path = File.join(secret_directory, "owned-secret.m4b")
    File.binwrite(secret_path, "private audible bytes")
    @upload.update!(
      original_filename: "#{secret_title}.m4b",
      file_path: secret_path,
      file_size: File.size(secret_path)
    )
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0FAILLOG#{SecureRandom.hex(3).upcase}",
      title: secret_title,
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )
    private_diagnostic = "reader failed for #{secret_title} at #{secret_path} #{'x' * 3_000}"

    logs = capture_upload_job_logs do
      MetadataExtractorService.stub(:extract, ->(*) { raise IOError, private_diagnostic }) do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end.join("\n")

    assert @upload.reload.failed?
    assert media_import.reload.failed?
    assert_includes logs, "IOError"
    assert_not_includes logs, secret_title
    assert_not_includes logs, secret_path
    assert_includes @upload.error_message, secret_title
    assert_operator @upload.error_message.length, :<=, UploadProcessingJob::USER_ERROR_MESSAGE_LIMIT
    assert_equal @upload.error_message, media_import.error_message
  ensure
    FileUtils.rm_rf(secret_directory) if secret_directory
  end

  test "preserves a matching library file acquired while Libation was downloading" do
    existing_directory = File.join(@temp_audiobook_dest, "Brandon Sanderson", "Mistborn")
    existing_file = File.join(existing_directory, "Brandon Sanderson - Mistborn.m4b")
    FileUtils.mkdir_p(existing_directory)
    File.binwrite(existing_file, "already acquired")
    existing = Book.create!(
      title: "Mistborn",
      author: "Brandon Sanderson",
      narrator: "Narrator",
      book_type: :audiobook,
      file_path: existing_directory
    )
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "B0LATELOCAL",
      title: "Mistborn",
      authors: [ "Brandon Sanderson" ],
      narrators: [ "Narrator" ],
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @user,
      upload: @upload,
      status: "processing"
    )
    @upload.update!(file_size: File.size(@test_file))

    VCR.turned_off do
      stub_open_library_search("Mistborn Brandon Sanderson")
      assert_no_difference -> { Book.count } do
        UploadProcessingJob.perform_now(@upload.id)
      end
    end

    assert @upload.reload.failed?
    assert_match(/became available|possible local-library match/, @upload.error_message)
    assert_equal "already acquired", File.binread(existing_file)
    assert_equal existing_directory, existing.reload.file_path
    assert File.exist?(@upload.file_path), "the durable staged copy remains available for diagnosis or retry"
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

  test "targeted upload completes an awaiting purchase request" do
    request = requests(:pending_request)
    request.update!(status: :awaiting_purchase)
    request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "purchased-upload",
      title: request.book.title,
      market: "PT",
      formats: [ "epub" ],
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/purchased-upload/"
    )
    ebook_file = File.join(@temp_source, "Purchased Ebook.epub")
    File.write(ebook_file, "purchased ebook content")
    upload = Upload.create!(
      user: request.user,
      request: request,
      original_filename: "Purchased Ebook.epub",
      file_path: ebook_file,
      file_size: File.size(ebook_file),
      status: :pending
    )

    assert_no_difference "Book.count" do
      UploadProcessingJob.perform_now(upload.id)
    end

    assert upload.reload.completed?
    assert_equal request.book, upload.book
    assert request.reload.completed?
    assert request.completed_at.present?
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
    assert File.zero?(zip_file), "completed ZIP source is securely truncated before later temp cleanup"
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

  test "audiobook zip preflight rejects a central size lie before extraction" do
    zip_file = File.join(@temp_source, "Lying Size Audiobook.zip")
    destination = File.join(@temp_audiobook_dest, "Lying Size")
    build_zip_archive(zip_file, "chapter_01.mp3" => "ten-bytes!")
    understate_zip_central_directory_size(zip_file, 1)

    require "zip"
    Zip::File.open(zip_file) { |archive| assert_equal 1, archive.first.size }

    error = assert_raises(RuntimeError) do
      UploadProcessingJob.new.send(:extract_zip_upload_to_directory, zip_file, destination, max_bytes: 5)
    end

    assert_includes error.message, "local and central sizes disagree"
    assert_not File.exist?(destination)
  end

  test "audiobook zip preflights actual central headers before rubyzip opens" do
    zip_file = File.join(@temp_source, "Understated Entries.zip")
    destination = File.join(@temp_audiobook_dest, "Understated Entries")
    build_zip_archive(
      zip_file,
      "chapter_01.mp3" => "audio-one",
      "chapter_02.mp3" => "audio-two"
    )
    bytes = File.binread(zip_file)
    end_record = bytes.rindex(ZipArchivePreflightService::END_OF_CENTRAL_DIRECTORY_SIGNATURE)
    bytes[end_record + 8, 4] = [ 1, 1 ].pack("vv")
    File.binwrite(zip_file, bytes)

    Zip::File.stub(:open, ->(*) { flunk "rubyzip opened an archive that failed preflight" }) do
      error = assert_raises(RuntimeError) do
        UploadProcessingJob.new.send(:extract_zip_upload_to_directory, zip_file, destination)
      end
      assert_includes error.message, "entry count"
    end

    assert_not File.exist?(destination)
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

  test "audiobook zip extraction rejects implicit directory amplification" do
    zip_file = File.join(@temp_source, "Deep Paths.zip")
    destination = File.join(@temp_audiobook_dest, "Deep Paths")
    build_zip_archive(
      zip_file,
      "one/two/three/chapter.mp3" => "audio-one",
      "four/five/six/chapter.mp3" => "audio-two"
    )

    error = assert_raises(RuntimeError) do
      UploadProcessingJob.new.send(
        :extract_zip_upload_to_directory,
        zip_file,
        destination,
        max_files: 2
      )
    end

    assert_includes error.message, "too many files and directories"
    assert_not File.exist?(destination)
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

  test "audiobook zip upload rejects a symlinked destination ancestor without writing outside the library" do
    request = requests(:failed_request)
    outside = Dir.mktmpdir("outside-audiobook-library")
    author_path = File.join(@temp_audiobook_dest, "Third Author")
    File.symlink(outside, author_path)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(zip_file, "chapter_01.mp3" => "trusted-audio")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: File.basename(zip_file),
      file_path: zip_file,
      file_size: File.size(zip_file),
      status: :pending
    )

    UploadProcessingJob.perform_now(upload.id)

    assert upload.reload.failed?
    assert_match(/symbolic link|safely publish|unsafe/i, upload.error_message)
    assert_empty Dir.children(outside)
    assert File.exist?(zip_file)
    assert_nil upload.destination_path
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "audiobook zip upload rejects a configured-root alias changed after reservation" do
    request = requests(:failed_request)
    configured_parent = Dir.mktmpdir("configured-audiobook-link")
    trusted_root = Dir.mktmpdir("trusted-audiobook-root")
    outside_root = Dir.mktmpdir("outside-audiobook-root")
    configured_link = File.join(configured_parent, "library")
    File.symlink(trusted_root, configured_link)
    SettingsService.set(:audiobook_output_path, configured_link)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(zip_file, "chapter_01.mp3" => "trusted-audio")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: File.basename(zip_file),
      file_path: zip_file,
      file_size: File.size(zip_file),
      book_type: :audiobook,
      status: :processing
    )
    service = UploadZipImportFileService.new(
      upload: upload,
      book: request.book,
      max_bytes: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES,
      max_files: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_FILES
    )
    service.reserve!
    File.unlink(configured_link)
    File.symlink(outside_root, configured_link)

    error = assert_raises(UploadZipImportFileService::Error) { service.publish! }

    assert_includes error.message, "configured audiobook root changed"
    assert_empty Dir.children(trusted_root).reject { |name| name.start_with?(".shelfarr") }
    assert_empty Dir.children(outside_root)
  ensure
    FileUtils.rm_rf(configured_parent) if configured_parent
    FileUtils.rm_rf(trusted_root) if trusted_root
    FileUtils.rm_rf(outside_root) if outside_root
  end

  test "audiobook zip upload resumes a complete tree published before worker termination" do
    request = requests(:failed_request)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(zip_file, "chapter_01.mp3" => "trusted-audio")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: File.basename(zip_file),
      file_path: zip_file,
      file_size: File.size(zip_file),
      book_type: :audiobook,
      status: :processing
    )
    service = UploadZipImportFileService.new(
      upload: upload,
      book: request.book,
      max_bytes: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES,
      max_files: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_FILES
    )
    service.reserve!
    destination = service.publish!

    assert File.exist?(File.join(destination, "chapter_01.mp3"))
    assert File.exist?(File.join(destination, UploadZipImportFileService::MANIFEST_FILENAME))
    assert File.exist?(zip_file), "publication preserves the source until database completion"

    upload.update!(status: :pending)
    UploadProcessingJob.perform_now(upload.id)

    assert upload.reload.completed?
    assert request.reload.completed?
    assert_equal destination, request.book.reload.file_path
    assert_equal "trusted-audio", File.binread(File.join(destination, "chapter_01.mp3"))
    assert_not File.exist?(File.join(destination, UploadZipImportFileService::MANIFEST_FILENAME))
    assert File.zero?(zip_file)

    # Simulate a process exit after marker removal but before the final SQLite
    # cleanup-source update. The cleanup pass must reconcile the display-path
    # alias and finish idempotently without touching the published tree.
    upload.update_column(:cleanup_source_path, File.realpath(zip_file))
    assert UploadZipImportFileService.cleanup_completed_source!(upload)
    assert_nil upload.reload.cleanup_source_path
    assert_equal "trusted-audio", File.binread(File.join(destination, "chapter_01.mp3"))
  end

  test "audiobook zip upload discards incomplete private staging and retries from its source" do
    request = requests(:failed_request)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(zip_file, "chapter_01.mp3" => "complete-audio")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: File.basename(zip_file),
      file_path: zip_file,
      file_size: File.size(zip_file),
      book_type: :audiobook,
      status: :processing
    )
    service = UploadZipImportFileService.new(
      upload: upload,
      book: request.book,
      max_bytes: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_EXTRACTED_BYTES,
      max_files: UploadProcessingJob::MAX_AUDIOBOOK_ZIP_FILES
    )
    service.reserve!
    stage = service.send(:staging_path)
    FileCopyService.secure_private_directory!(stage, root: upload.destination_root)
    File.binwrite(File.join(stage, "chapter_01.mp3"), "partial")

    upload.update!(status: :pending)
    UploadProcessingJob.perform_now(upload.id)

    destination = request.book.reload.file_path
    assert upload.reload.completed?
    assert_equal "complete-audio", File.binread(File.join(destination, "chapter_01.mp3"))
    assert_not File.exist?(stage)
    assert File.zero?(zip_file)
  end

  test "audiobook zip rolls back a fully published tree on a book CAS conflict and remains retryable" do
    request = requests(:failed_request)
    zip_file = File.join(@temp_source, "Third Author - The Failed Audiobook.zip")
    build_zip_archive(zip_file, "chapter_01.mp3" => "trusted-audio")
    upload = Upload.create!(
      user: @user,
      request: request,
      original_filename: File.basename(zip_file),
      file_path: zip_file,
      file_size: File.size(zip_file),
      status: :pending
    )
    published_destination = nil
    original_claim = UploadProcessingJob.instance_method(:claim_book_file_path!)
    conflicting_job = UploadProcessingJob.new
    conflicting_job.define_singleton_method(:claim_book_file_path!) do |book, destination, current_upload|
      published_destination = destination
      book.update_columns(file_path: "/library/a-competing-copy")
      original_claim.bind_call(self, book, destination, current_upload)
    end

    conflicting_job.perform(upload.id)

    assert upload.reload.failed?
    assert_includes upload.error_message, "existing file was preserved"
    assert request.reload.failed?
    assert_nil request.book.reload.file_path
    assert_not File.exist?(published_destination)
    assert File.exist?(zip_file)
    assert_not File.zero?(zip_file)
    assert_nil upload.destination_path

    upload.update!(status: :pending, error_message: nil)
    UploadProcessingJob.perform_now(upload.id)

    assert upload.reload.completed?
    assert request.reload.completed?
    assert_equal "trusted-audio", File.binread(File.join(request.book.reload.file_path, "chapter_01.mp3"))
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

  test "only one delivery can atomically claim a pending upload" do
    first = UploadProcessingJob.new.send(:claim_pending_upload, @upload.id)
    second = UploadProcessingJob.new.send(:claim_pending_upload, @upload.id)

    assert_equal @upload.id, first.id
    assert_nil second
    assert @upload.reload.processing?
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

  test "trigger_library_scan uses configured comic book library" do
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "comic-lib")
    book = Book.create!(title: "Saga #1", author: "Brian K. Vaughan", book_type: :comicbook, content_kind: :graphic)
    scanned = []

    LibraryPlatformClient.stub(:scan_library, ->(library_id) { scanned << library_id }) do
      UploadProcessingJob.new.send(:trigger_library_scan, book)
    end

    assert_equal [ "comic-lib" ], scanned
  end

  private

  def capture_upload_job_logs(&job)
    original_rails_logger = Rails.logger
    original_database_logger = ActiveRecord::Base.logger
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    logger.level = Logger::DEBUG
    Rails.logger = logger
    ActiveRecord::Base.logger = logger

    job.call
    output.string.lines(chomp: true)
  ensure
    ActiveRecord::Base.logger = original_database_logger
    Rails.logger = original_rails_logger
  end

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

  def understate_zip_central_directory_size(path, reported_size)
    bytes = File.binread(path)
    offset = bytes.index("PK\x01\x02".b)
    raise "ZIP central directory was not found" unless offset

    bytes[offset + 24, 4] = [ reported_size ].pack("V")
    File.binwrite(path, bytes)
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
