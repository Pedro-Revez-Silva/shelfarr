# frozen_string_literal: true

require "test_helper"

class AdminAcquisitionRemovalTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @user = users(:one)
    sign_in_as(@admin)
  end

  test "admin can delete a downloading request and the client job is stopped" do
    book = Book.create!(title: "Stop the client", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :downloading)
    client = DownloadClient.create!(
      name: "Admin removal #{SecureRandom.hex(4)}",
      client_type: :qbittorrent,
      url: "http://127.0.0.1:9",
      enabled: true,
      priority: 0
    )
    download = request.downloads.create!(
      name: "Stop the client",
      status: :downloading,
      download_client: client,
      external_id: "abc123deadbeef"
    )
    removed = []
    adapter = Object.new
    adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
      removed << [ external_id, delete_files ]
      true
    end

    DownloadClients::Qbittorrent.stub(:new, adapter) do
      assert_difference [ "Request.count", "Download.count", "Book.count" ], -1 do
        delete request_path(request)
      end
    end

    assert_redirected_to requests_path
    assert_equal "Request cancelled", flash[:notice]
    assert_not Request.exists?(request.id)
    assert_not Download.exists?(download.id)
    assert_equal [ [ "abc123deadbeef", false ] ], removed
  end

  test "admin sees cancel for a request whose import owner is not running" do
    book = Book.create!(title: "Finished owner visible", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :processing)
    request.downloads.create!(
      name: book.title,
      status: :completed,
      post_processing_job_id: "finished-owner-not-in-queue"
    )

    get request_path(request)

    assert_response :success
    assert_select "button", text: "Cancel Request"
  end

  test "a regular user still cannot cancel another user's downloading request" do
    sign_out
    sign_in_as(@user)
    book = Book.create!(title: "Not yours", book_type: :ebook)
    request = Request.create!(book: book, user: @admin, status: :downloading)

    assert_no_difference "Request.count" do
      delete request_path(request)
    end

    assert_response :not_found
    assert Request.exists?(request.id)
  end

  test "admin can remove a library item while its download is still queued" do
    Dir.mktmpdir("shelfarr-admin-library-delete") do |dir|
      library_file = File.join(dir, "queued.epub")
      File.binwrite(library_file, "library bytes to remove")
      outside = File.join(dir, "outside", "notes.txt")
      FileUtils.mkdir_p(File.dirname(outside))
      File.binwrite(outside, "leave this file")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Queued library delete",
        book_type: :ebook,
        file_path: library_file
      )
      request = Request.create!(book: book, user: @user, status: :downloading)
      client = DownloadClient.create!(
        name: "Library removal #{SecureRandom.hex(4)}",
        client_type: :qbittorrent,
        url: "http://127.0.0.1:9",
        enabled: true,
        priority: 1
      )
      request.downloads.create!(
        name: book.title,
        status: :queued,
        download_client: client,
        external_id: "libraryjob1"
      )
      removed = []
      adapter = Object.new
      adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
        removed << [ external_id, delete_files ]
        true
      end

      DownloadClients::Qbittorrent.stub(:new, adapter) do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_index_path
      assert_match(/removed from the library/, flash[:notice].to_s)
      assert_not Book.exists?(book.id)
      assert_not Request.exists?(request.id)
      assert_not File.exist?(library_file)
      assert_equal "leave this file", File.binread(outside)
      assert_equal [ [ "libraryjob1", false ] ], removed
    end
  end

  test "admin can delete a library item after its importer has finished" do
    Dir.mktmpdir("shelfarr-finished-owner") do |dir|
      library_file = File.join(dir, "finished.epub")
      File.binwrite(library_file, "finished import bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Finished import", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :processing)
      request.downloads.create!(
        name: book.title,
        status: :completed,
        post_processing_job_id: "finished-import-owner"
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path, flash[:alert].to_s
      assert_not Book.exists?(book.id)
      assert_not File.exist?(library_file)
    end
  end

  test "a running library import still blocks admin removal" do
    Dir.mktmpdir("shelfarr-live-import") do |dir|
      library_file = File.join(dir, "live.epub")
      File.binwrite(library_file, "live import bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Live import library", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :processing)
      download = request.downloads.create!(
        name: book.title,
        status: :completed,
        post_processing_job_id: "live-import-owner"
      )
      queue_job = SolidQueue::Job.create!(
        active_job_id: "live-import-owner",
        class_name: "PostProcessingJob",
        queue_name: "default",
        arguments: { "job_class" => "PostProcessingJob", "arguments" => [] },
        priority: 0,
        scheduled_at: Time.current
      )

      assert_no_difference [ "Book.count", "Request.count", "Download.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/post-processing/i, flash[:alert])
      assert_equal "live import bytes", File.binread(library_file)
      assert_equal "live-import-owner", download.reload.post_processing_job_id
    ensure
      if queue_job
        SolidQueue::ReadyExecution.where(job_id: queue_job.id).delete_all
        SolidQueue::ScheduledExecution.where(job_id: queue_job.id).delete_all
        SolidQueue::ClaimedExecution.where(job_id: queue_job.id).delete_all
        SolidQueue::BlockedExecution.where(job_id: queue_job.id).delete_all
        SolidQueue::FailedExecution.where(job_id: queue_job.id).delete_all
        queue_job.delete
      end
    end
  end

  test "an unfinished cleanup journal still blocks admin removal" do
    Dir.mktmpdir("shelfarr-cleanup-journal") do |dir|
      library_file = File.join(dir, "journal.epub")
      File.binwrite(library_file, "journal bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Cleanup journal", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :completed)
      download = request.downloads.create!(
        name: book.title,
        status: :completed,
        post_processing_cleanup_state: "{\"source\":\"kept\"}"
      )

      assert_no_difference [ "Book.count", "Request.count", "Download.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/post-processing/i, flash[:alert])
      assert_equal "journal bytes", File.binread(library_file)
      assert_equal "{\"source\":\"kept\"}", download.reload.post_processing_cleanup_state

      assert_no_difference [ "Request.count", "Download.count" ] do
        delete request_path(request)
      end

      assert_redirected_to request_path(request)
      assert_match(/post-processing/i, flash[:alert])
      assert Download.exists?(download.id)
    end
  end

  test "admin can delete a library item that only has a pending upload" do
    Dir.mktmpdir("shelfarr-pending-upload-delete") do |dir|
      library_file = File.join(dir, "pending-upload.epub")
      File.binwrite(library_file, "pending upload library bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Pending upload library",
        book_type: :ebook,
        file_path: library_file
      )
      request = Request.create!(book: book, user: @user, status: :pending)
      upload = Upload.create!(
        user: @user,
        request: request,
        original_filename: "pending.epub",
        file_path: "/tmp/pending-library-delete.epub",
        status: :pending
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path, flash[:alert].to_s
      assert_not Book.exists?(book.id)
      assert_not Request.exists?(request.id)
      assert_not Upload.exists?(upload.id)
      assert_not File.exist?(library_file)
    end
  end

  test "a processing upload still blocks library removal" do
    Dir.mktmpdir("shelfarr-processing-upload") do |dir|
      library_file = File.join(dir, "processing.epub")
      File.binwrite(library_file, "processing upload bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Processing upload library",
        book_type: :ebook,
        file_path: library_file
      )
      request = Request.create!(book: book, user: @user, status: :downloading)
      upload = Upload.create!(
        user: @user,
        request: request,
        original_filename: "processing.epub",
        file_path: library_file,
        status: :processing
      )

      assert_no_difference [ "Book.count", "Request.count", "Upload.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/upload/i, flash[:alert])
      assert_equal "processing upload bytes", File.binread(library_file)
      assert Upload.exists?(upload.id)
    end
  end

  test "admin cancel removes a partial first import that this import published" do
    Dir.mktmpdir("shelfarr-partial-import") do |root|
      library = File.join(root, "audiobooks")
      source = File.join(root, "download")
      FileUtils.mkdir_p(library)
      FileUtils.mkdir_p(source)
      SettingsService.set(:audiobook_output_path, library)
      SettingsService.set(:audiobook_path_template, "{author}/{title}")
      File.binwrite(File.join(source, "01.mp3"), "one")
      File.binwrite(File.join(source, "02.mp3"), "two")
      partial = File.join(library, "Ada", "Title")
      published = File.join(partial, "01.mp3")
      FileUtils.mkdir_p(partial)
      File.binwrite(published, "one")
      book = Book.create!(title: "Title", author: "Ada", book_type: :audiobook)
      request = Request.create!(
        book: book,
        user: @user,
        status: :processing,
        attention_needed: true,
        issue_description: "Import failed"
      )
      request.downloads.create!(
        name: book.title,
        status: :completed,
        download_path: source,
        post_processing_job_id: "finished-partial-import",
        library_replacement_state: JSON.generate("published_paths" => [ published ])
      )

      assert_difference [ "Request.count", "Download.count", "Book.count" ], -1 do
        delete request_path(request)
      end

      assert_redirected_to requests_path
      assert_equal "Request cancelled", flash[:notice]
      assert_not File.exist?(partial)
      assert_equal "two", File.binread(File.join(source, "02.mp3"))
    end
  end

  test "admin cancel removes only a published partial and leaves an unrelated file" do
    Dir.mktmpdir("shelfarr-unrelated-partial") do |root|
      library = File.join(root, "audiobooks")
      source = File.join(root, "download")
      FileUtils.mkdir_p(library)
      FileUtils.mkdir_p(source)
      SettingsService.set(:audiobook_output_path, library)
      SettingsService.set(:audiobook_path_template, "{author}/{title}")
      File.binwrite(File.join(source, "01.mp3"), "one")
      File.binwrite(File.join(source, "02.mp3"), "two")
      partial = File.join(library, "Ada", "Title")
      published = File.join(partial, "01.mp3")
      unrelated = File.join(partial, "unrelated.mp3")
      FileUtils.mkdir_p(partial)
      File.binwrite(published, "one")
      File.binwrite(unrelated, "leave this")
      book = Book.create!(title: "Title", author: "Ada", book_type: :audiobook)
      request = Request.create!(
        book: book,
        user: @user,
        status: :processing,
        attention_needed: true,
        issue_description: "Import failed"
      )
      request.downloads.create!(
        name: book.title,
        status: :completed,
        download_path: source,
        post_processing_job_id: "finished-unrelated-import",
        library_replacement_state: JSON.generate("published_paths" => [ published ])
      )

      assert_difference [ "Request.count", "Download.count", "Book.count" ], -1 do
        delete request_path(request)
      end

      assert_redirected_to requests_path
      assert_equal "Request cancelled", flash[:notice]
      assert_equal "leave this", File.binread(unrelated)
      assert_not File.exist?(published)
      assert_not Book.exists?(book.id)
    end
  end

  test "admin is asked before a manual result replaces a library file" do
    book = Book.create!(
      title: "Already here",
      author: "Ada Lovelace",
      book_type: :ebook,
      file_path: "/ebooks/already-here.epub"
    )
    request = Request.create!(book: book, user: @user, status: :completed)
    result = request.search_results.create!(
      guid: "gutenberg:already",
      title: "Already here [PDF]",
      indexer: "Project Gutenberg",
      source: SearchResult::SOURCE_GUTENBERG,
      download_url: "https://www.gutenberg.org/ebooks/1.pdf.images?download=1",
      status: :pending
    )

    get request_path(request)

    assert_response :success
    assert_match(/already in the library/i, response.body)
    assert_select "form[action=?][data-turbo-confirm=?]",
      select_admin_request_search_result_path(request, result),
      Request::LIBRARY_FILE_REPLACEMENT_PROMPT do
      assert_select "input[name='replace_library_file'][value='1']"
    end
  end

  test "admin cancel leaves a torrent that another request now owns" do
    shared_hash = "0123456789abcdef0123456789abcdef01234567"
    active_hash = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
    client = DownloadClient.create!(
      name: "Shared hash #{SecureRandom.hex(4)}",
      client_type: :qbittorrent,
      url: "http://127.0.0.1:9",
      enabled: true,
      priority: 2
    )
    book_a = Book.create!(title: "Bundle A", book_type: :audiobook)
    request_a = Request.create!(book: book_a, user: @user, status: :downloading)
    request_a.downloads.create!(
      name: "Earlier bundle download",
      status: :failed,
      download_client: client,
      external_id: shared_hash
    )
    request_a.downloads.create!(
      name: "Current download",
      status: :downloading,
      download_client: client,
      external_id: active_hash
    )
    book_b = Book.create!(title: "Bundle B", book_type: :audiobook)
    request_b = Request.create!(book: book_b, user: @user, status: :downloading)
    owned = request_b.downloads.create!(
      name: "Bundle B download",
      status: :downloading,
      download_client: client,
      external_id: shared_hash
    )
    removed = []
    adapter = Object.new
    adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
      removed << [ external_id, delete_files ]
      true
    end
    adapter.define_singleton_method(:torrent_info) { |_external_id| nil }

    DownloadClients::Qbittorrent.stub(:new, adapter) do
      delete request_path(request_a)
    end

    assert_redirected_to requests_path
    assert_equal "Request cancelled", flash[:notice]
    assert_not Request.exists?(request_a.id)
    assert_equal [ [ active_hash, false ] ], removed
    assert owned.reload.downloading?
    assert_equal shared_hash, owned.external_id
  end

  test "library removal keeps the book when the download client cannot be reached" do
    Dir.mktmpdir("shelfarr-client-offline") do |dir|
      library_file = File.join(dir, "offline.epub")
      File.binwrite(library_file, "keep these bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Client offline", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :downloading)
      client = DownloadClient.create!(
        name: "Offline client #{SecureRandom.hex(4)}",
        client_type: :qbittorrent,
        url: "http://127.0.0.1:9",
        enabled: true,
        priority: 3
      )
      download = request.downloads.create!(
        name: book.title,
        status: :downloading,
        download_client: client,
        external_id: "offlinehash1"
      )
      attempts = 0
      adapter = Object.new
      adapter.define_singleton_method(:remove_torrent) do |_external_id, delete_files:|
        attempts += 1
        raise DownloadClients::Base::ConnectionError, "client offline" if attempts == 1

        true
      end
      adapter.define_singleton_method(:torrent_info) { |_external_id| nil }

      DownloadClients::Qbittorrent.stub(:new, adapter) do
        delete library_path(book), params: { delete_files: "1" }

        assert_redirected_to library_path(book)
        assert_match(/download client/i, flash[:alert])
        assert Book.exists?(book.id)
        assert Request.exists?(request.id)
        assert Download.exists?(download.id)
        assert_equal "keep these bytes", File.binread(library_file)

        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_index_path
      assert_not Book.exists?(book.id)
      assert_not File.exist?(library_file)
      assert_equal 2, attempts
    end
  end

  test "library removal stops a completed torrent that is still seeding" do
    Dir.mktmpdir("shelfarr-seeding-removal") do |dir|
      library_file = File.join(dir, "seeded.epub")
      File.binwrite(library_file, "seeded bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Still seeding", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :processing)
      client = DownloadClient.create!(
        name: "Seeding removal #{SecureRandom.hex(4)}",
        client_type: :qbittorrent,
        url: "http://127.0.0.1:9",
        enabled: true,
        priority: 4
      )
      info_hash = "0123456789abcdef0123456789abcdef01234567"
      download = request.downloads.create!(
        name: book.title,
        status: :completed,
        download_client: client,
        external_id: info_hash,
        progress: 100
      )
      request.complete!
      assert download.reload.external_id_released_at
      removed = []
      adapter = Object.new
      adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
        removed << [ external_id, delete_files ]
        true
      end
      adapter.define_singleton_method(:torrent_info) { |_external_id| nil }

      DownloadClients::Qbittorrent.stub(:new, adapter) do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_index_path, flash[:alert].to_s
      assert_not Book.exists?(book.id)
      assert_not Request.exists?(request.id)
      assert_not File.exist?(library_file)
      assert_equal [ [ info_hash, false ] ], removed
    end
  end

  test "library removal leaves a seeding torrent that another request now owns" do
    Dir.mktmpdir("shelfarr-seeding-owner") do |dir|
      library_file = File.join(dir, "owned-seed.epub")
      File.binwrite(library_file, "owned seed bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(title: "Released seed", book_type: :ebook, file_path: library_file)
      request = Request.create!(book: book, user: @user, status: :processing)
      client = DownloadClient.create!(
        name: "Seeding owner #{SecureRandom.hex(4)}",
        client_type: :qbittorrent,
        url: "http://127.0.0.1:9",
        enabled: true,
        priority: 5
      )
      info_hash = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
      request.downloads.create!(
        name: book.title,
        status: :completed,
        download_client: client,
        external_id: info_hash,
        progress: 100
      )
      request.complete!
      other_book = Book.create!(title: "Current owner", book_type: :ebook)
      other_request = Request.create!(book: other_book, user: @user, status: :downloading)
      owned = other_request.downloads.create!(
        name: "Current owner download",
        status: :downloading,
        download_client: client,
        external_id: info_hash
      )
      removed = []
      adapter = Object.new
      adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
        removed << [ external_id, delete_files ]
        true
      end
      adapter.define_singleton_method(:torrent_info) { |_external_id| nil }

      DownloadClients::Qbittorrent.stub(:new, adapter) do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_index_path, flash[:alert].to_s
      assert_not Book.exists?(book.id)
      assert_empty removed
      assert owned.reload.downloading?
      assert_equal info_hash, owned.external_id
    end
  end
end
