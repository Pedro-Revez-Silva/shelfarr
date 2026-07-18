# frozen_string_literal: true

require "test_helper"

class RequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    @admin = users(:two)
    @pending_request = requests(:pending_request)
    @failed_request = requests(:failed_request)
    sign_in_as(@user)
  end

  test "index requires authentication" do
    sign_out
    get requests_path
    assert_response :redirect
  end

  test "index shows user's requests" do
    get requests_path
    assert_response :success
    assert_select "h1", "My Requests"
  end

  test "admin sees all requests" do
    sign_out
    sign_in_as(@admin)
    get requests_path
    assert_response :success
    assert_select "h1", "All Requests"
  end

  test "index renders request cards with narrow-screen wrapping constraints" do
    sign_out
    sign_in_as(@admin)

    get requests_path

    assert_response :success
    assert_select "[data-request-card-header][class~='items-stretch'][class~='sm:items-start']"
    assert_select "[data-request-card-header] > [class~='w-full'][class~='sm:flex-1']"
    assert_select "[data-request-card-action-row][class~='items-stretch'][class~='sm:items-center']"
    assert_select "[data-request-card-action-row] > [class~='max-w-full'][class~='sm:flex-1']"
  end

  test "index filters by status" do
    sign_out
    sign_in_as(@admin)

    # Create requests with different statuses
    completed_request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :completed
    )

    get requests_path(status: "completed")
    assert_response :success

    # Should only show completed requests
    assert_select "h3", completed_request.book.title
  end

  test "index filters by active status excluding attention needed" do
    sign_out
    sign_in_as(@admin)

    # Create unique books for this test
    active_book = Book.create!(
      title: "Active Test Book Unique",
      book_type: :ebook,
      open_library_work_id: "OL_ACTIVE_FILTER_TEST"
    )
    attention_book = Book.create!(
      title: "Attention Test Book Unique",
      book_type: :ebook,
      open_library_work_id: "OL_ATTENTION_FILTER_TEST"
    )

    # Create an active request without attention needed
    active_request = Request.create!(
      book: active_book,
      user: @user,
      status: :pending,
      attention_needed: false
    )

    # Create an active request with attention needed
    attention_request = Request.create!(
      book: attention_book,
      user: @user,
      status: :searching,
      attention_needed: true
    )

    get requests_path(status: "active")
    assert_response :success

    # Active filter should exclude requests needing attention
    assert_select "h3", text: "Active Test Book Unique"
    assert_select "h3", text: "Attention Test Book Unique", count: 0
  end

  test "index filters by attention needed" do
    sign_out
    sign_in_as(@admin)

    # Create a request needing attention
    attention_request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :downloading,
      attention_needed: true,
      issue_description: "Download failed"
    )

    get requests_path(attention: "true")
    assert_response :success

    # Should show requests needing attention
    assert_select "h3", attention_request.book.title
  end

  test "index shows attention count and active count" do
    sign_out
    sign_in_as(@admin)

    get requests_path
    assert_response :success

    # Should have filter tabs rendered
    assert_select "a", text: /Need Attention/
    assert_select "a", text: /Active/
  end

  test "show displays request details" do
    get request_path(@pending_request)
    assert_response :success
    assert_select "h1", @pending_request.book.title
    assert_select "meta[name='action-cable-url']", 1
    assert_select "turbo-cable-stream-source[channel='Turbo::StreamsChannel']", 1
  end

  test "show presents DRM-free store offers to the request owner" do
    SettingsService.set(:allow_user_uploads, true)
    offer = create_store_offer

    get request_path(@pending_request)

    assert_response :success
    assert_select "section[data-store-offers][aria-labelledby='store-offers-heading']", count: 1 do
      assert_select "h3#store-offers-heading", text: /Buy DRM-free/
      assert_select "[role='status'], [aria-live]", count: 0
    end
    assert_select "[data-store-offer]", count: 1
    assert_select "a[href='#{offer.storefront_url}'][target='_blank'][rel='noopener noreferrer']", text: /View & buy at eBooks.com/
    assert_select "time[datetime='#{offer.quoted_at.iso8601}']", text: /Checked .* ago/
    assert_select "a[href='#{new_upload_path(request_id: @pending_request.id)}']", text: "Upload after purchase"
    assert_select "form[action*='/admin/requests/']", count: 0
  ensure
    SettingsService.set(:allow_user_uploads, false)
  end

  test "show does not expose a purchased-file upload action when user uploads are disabled" do
    SettingsService.set(:allow_user_uploads, false)
    create_store_offer

    get request_path(@pending_request)

    assert_response :success
    assert_select "[data-store-offer]", count: 1
    assert_select "a", text: "Upload after purchase", count: 0
    assert_select "p", text: /ask an administrator to import it into this request/
  end

  test "show hides and purges store offers when the provider is disabled" do
    create_store_offer
    SettingsService.set(:ebooks_com_enabled, false)

    get request_path(@pending_request)

    assert_response :success
    assert_select "[data-store-offers]", count: 0
    assert_empty @pending_request.reload.store_offers
  end

  test "show hides store offers after the request is completed" do
    create_store_offer
    @pending_request.complete!

    get request_path(@pending_request)

    assert_response :success
    assert_select "[data-store-offers]", count: 0
  end

  test "show links admins to upload a file for an open request" do
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)

    assert_response :success
    assert_select "a[href='#{new_admin_upload_path(request_id: @pending_request.id)}']", text: "Upload File"
  end

  test "show links regular users to request upload when uploads are enabled" do
    SettingsService.set(:allow_user_uploads, true)

    get request_path(@pending_request)

    assert_response :success
    assert_select "a[href='#{new_upload_path(request_id: @pending_request.id)}']", text: "Upload File"
  end

  test "show hides request upload link from regular users when uploads are disabled" do
    SettingsService.set(:allow_user_uploads, false)

    get request_path(@pending_request)

    assert_response :success
    assert_select "a[href='#{new_upload_path(request_id: @pending_request.id)}']", count: 0
  end

  test "show hides request upload link for completed requests" do
    @pending_request.complete!
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)

    assert_response :success
    assert_select "a[href='#{new_admin_upload_path(request_id: @pending_request.id)}']", count: 0
  end

  test "show keeps search results hidden from regular users" do
    @pending_request.update!(status: :searching)

    get request_path(@pending_request)
    assert_response :success

    assert_select "h3", text: "Search Results Available"
    assert_select "p", text: "Waiting for admin approval."
    assert_select "p", text: /The Pending Ebook - Complete Audiobook/, count: 0
    assert_select "form[action='#{select_admin_request_search_result_path(@pending_request, search_results(:pending_result))}']", count: 0
  end

  test "show displays inline search results for admins" do
    @pending_request.update!(status: :searching)
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)
    assert_response :success

    assert_select "h3", text: /Search Results/
    assert_select "p", text: /The Pending Ebook - Complete Audiobook/
    assert_select "form[action='#{select_admin_request_search_result_path(@pending_request, search_results(:pending_result))}']"
  end

  test "show displays diagnostics timeline for request activity" do
    sign_out
    sign_in_as(@admin)

    RequestEvent.create!(
      request: @pending_request,
      event_type: "dispatch_failed",
      source: "DownloadJob",
      level: :error,
      message: "Failed to connect to download client",
      details: {
        client_name: "SABnzbd"
      }
    )

    get request_path(@pending_request)
    assert_response :success
    assert_select "h3", "Diagnostics"
    assert_select "p", text: /Failed to connect to download client/
    assert_select "p", text: /SABnzbd/
  end

  test "show hides diagnostics timeline from regular users" do
    RequestEvent.create!(
      request: @pending_request,
      event_type: "dispatch_failed",
      source: "DownloadJob",
      level: :error,
      message: "Failed to connect to download client"
    )

    get request_path(@pending_request)
    assert_response :success
    assert_select "h3", text: "Diagnostics", count: 0
  end

  test "user cannot view another user's request" do
    other_user = users(:two)
    other_request = Request.create!(
      book: books(:audiobook_acquired),
      user: other_user,
      status: :pending
    )

    get request_path(other_request)
    assert_response :not_found
  end

  test "admin can view any request" do
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)
    assert_response :success
  end

  test "show links admins to search results after auto selection" do
    @pending_request.update!(status: :downloading)
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)
    assert_response :success

    assert_select "a[href='#{admin_request_search_results_path(@pending_request)}']", text: "Manage Results"
  end

  test "show hides completed search result controls from regular users" do
    @pending_request.update!(status: :downloading)

    get request_path(@pending_request)
    assert_response :success

    assert_select "a[href='#{admin_request_search_results_path(@pending_request)}']", count: 0
    assert_select "h3", text: "Search Results Available", count: 0
  end

  test "index shows results and retry actions independently" do
    @failed_request.search_results.create!(
      guid: "failed-result-guid",
      title: "Failed Result",
      download_url: "http://example.com/failed.torrent",
      status: :rejected
    )
    sign_out
    sign_in_as(@admin)

    get requests_path
    assert_response :success

    assert_select "button", text: /View Results/
    assert_select "form[action='#{retry_request_path(@failed_request)}']"
  end

  test "new requires work_id and title" do
    get new_request_path
    assert_redirected_to search_path
    assert_equal "Missing book information", flash[:alert]
  end

  test "new shows request form with book info" do
    get new_request_path, params: {
      work_id: "OL12345W",
      title: "Test Book",
      author: "Test Author"
    }
    assert_response :success
    assert_select "h2", "Test Book"
  end

  test "new uses server-authoritative book formats" do
    get new_request_path, params: {
      work_id: "google_books:gb-ebook-only",
      title: "Ebook Only",
      author: "Format Author",
      available_book_types: [ "ebook" ]
    }

    assert_response :success
    assert_select "input[name='book_types[]'][value='ebook']"
    assert_select "input[name='book_types[]'][value='audiobook']"
    assert_select "span", text: "Ebook"
    assert_select "span", text: "Audiobook"
  end

  test "new normalizes legacy graphic content kinds" do
    get new_request_path, params: {
      work_id: "comic_vine:4000-legacy-comic",
      title: "Legacy Comic",
      content_kind: "comic",
      available_book_types: [ "ebook" ]
    }

    assert_response :success
    assert_select "input[name='book_types[]'][value='comicbook'][checked]"
    assert_select "input[name='book_types[]'][value='ebook']", count: 0
  end

  test "new treats Comic Vine identity as graphic when the supplied kind is wrong" do
    get new_request_path, params: {
      work_id: "comic_vine:4000-source-policy",
      title: "Source Policy",
      content_kind: "book"
    }

    assert_response :success
    assert_select "input[name='content_kind'][value='graphic']"
    assert_select "input[name='book_types[]'][value='comicbook'][checked]"
    assert_select "input[name='book_types[]'][value='ebook']", count: 0
  end

  test "create creates book and request" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      post requests_path, params: {
        work_id: "OL_NEW_123W",
        title: "New Book",
        author: "New Author",
        book_type: "audiobook"
      }
    end

    book = Book.last
    assert_equal "New Book", book.title
    assert_equal "audiobook", book.book_type
    assert_equal @user, book.requests.last.user
    assert_redirected_to request_path(Request.last)
  end

  test "create preserves errors when request creation partially succeeds" do
    book = Book.create!(title: "Saga #1", book_type: :comicbook, content_kind: :graphic, comic_vine_id: "4000-101")
    created_request = Request.create!(book: book, user: @user, status: :pending)
    result = RequestCreationService::Result.new(
      created_requests: [ created_request ],
      warnings: [],
      errors: [ "Saga #2 Comics & Manga: This Comics & Manga title already has an active request." ]
    )

    RequestCreationService.stub(:call, result) do
      post requests_path, params: {
        work_id: "comic_vine:4050-99",
        title: "Saga",
        book_type: "comicbook",
        request_scope: "collection",
        collection_source: "comic_vine",
        collection_id: "4050-99",
        collection_title: "Saga"
      }
    end

    assert_redirected_to request_path(created_request)
    assert_match "Request created for Saga #1", flash[:notice]
    assert_match "Saga #2", flash[:alert]
  end

  test "create queues collection requests for background expansion" do
    ComicVineClient.stub(:configured?, true) do
      assert_enqueued_with(job: CollectionRequestExpansionJob) do
        post requests_path, params: {
          work_id: "comic_vine:4050-99",
          title: "Saga",
          content_kind: "comic",
          book_type: "comicbook",
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      end
    end

    assert_redirected_to requests_path
    assert_match "Collection request queued", flash[:notice]
  end

  test "create stores series from metadata details" do
    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "123",
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      description: "Book one of The Expanse",
      year: 2011,
      cover_url: "https://example.com/cover.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "The Expanse",
      series_position: "1"
    )

    MetadataService.stub(:book_details, details) do
      assert_difference [ "Book.count", "Request.count" ], 1 do
        post requests_path, params: {
          work_id: "hardcover:123",
          title: "Leviathan Wakes",
          author: "James S. A. Corey",
          book_type: "ebook"
        }
      end
    end

    book = Book.last
    assert_equal "The Expanse", book.series
    assert_equal "1", book.series_position
    assert_equal "Book one of The Expanse", book.description
    assert_equal 2011, book.year
  end

  test "create backfills missing series on an existing book" do
    existing_book = Book.create!(
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      book_type: :ebook,
      hardcover_id: "456",
      series: nil
    )

    details = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "456",
      title: "Leviathan Wakes",
      author: "James S. A. Corey",
      description: "Book one of The Expanse",
      year: 2011,
      cover_url: nil,
      has_audiobook: true,
      has_ebook: true,
      series_name: "The Expanse",
      series_position: "2"
    )

    MetadataService.stub(:book_details, details) do
      assert_no_difference "Book.count" do
        post requests_path, params: {
          work_id: "hardcover:456",
          title: "Leviathan Wakes",
          author: "James S. A. Corey",
          book_type: "ebook"
        }
      end
    end

    existing_book.reload
    assert_equal "The Expanse", existing_book.series
    assert_equal "2", existing_book.series_position
  end

  test "create falls back to request params when metadata details lookup fails" do
    MetadataService.stub(:book_details, ->(*) { raise OpenLibraryClient::ConnectionError, "timeout" }) do
      assert_difference [ "Book.count", "Request.count" ], 1 do
        post requests_path, params: {
          work_id: "OL_FALLBACK_123W",
          title: "Fallback Book",
          author: "Fallback Author",
          book_type: "ebook"
        }
      end
    end

    book = Book.last
    assert_equal "Fallback Book", book.title
    assert_equal "Fallback Author", book.author
    assert_nil book.series
  end

  test "create enqueues request_created webhook event" do
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_events, "request_created")

    assert_enqueued_with(job: OutboundWebhookDeliveryJob) do
      post requests_path, params: {
        work_id: "OL_WEBHOOK_123W",
        title: "Webhook Book",
        author: "Webhook Author",
        book_type: "audiobook"
      }
    end

    enqueued = enqueued_jobs.find { |job| job[:job] == OutboundWebhookDeliveryJob }
    args = enqueued[:args].first.with_indifferent_access
    assert_equal "request_created", args[:event]
  end

  test "create auto-approves non-admin requests when setting is enabled" do
    SettingsService.set(:auto_approve_requests, true)

    assert_enqueued_with(job: SearchJob) do
      post requests_path, params: {
        work_id: "OL_AUTO_APPROVE_123W",
        title: "Auto Approve Book",
        author: "Trusted User",
        book_type: "ebook"
      }
    end

    assert_redirected_to request_path(Request.last)
  end

  test "create does not auto-approve admin requests when only auto approve requests is enabled" do
    SettingsService.set(:auto_approve_requests, true)
    sign_out
    sign_in_as(@admin)

    assert_no_enqueued_jobs only: SearchJob do
      post requests_path, params: {
        work_id: "OL_ADMIN_CREATE_123W",
        title: "Admin Queue Book",
        author: "Admin",
        book_type: "ebook"
      }
    end

    assert_redirected_to request_path(Request.last)
  end

  test "create enqueues search only once when immediate search and auto approve are both enabled" do
    SettingsService.set(:immediate_search_enabled, true)
    SettingsService.set(:auto_approve_requests, true)

    assert_enqueued_jobs 1, only: SearchJob do
      post requests_path, params: {
        work_id: "OL_BOTH_FLAGS_123W",
        title: "Dual Trigger Book",
        author: "Trusted User",
        book_type: "ebook"
      }
    end
  end

  test "create reuses existing book" do
    existing_book = Book.create!(
      title: "Existing",
      book_type: :ebook,
      open_library_work_id: "OL_EXISTING_W"
    )

    assert_no_difference "Book.count" do
      assert_difference "Request.count", 1 do
        post requests_path, params: {
          work_id: "OL_EXISTING_W",
          title: "Existing",
          book_type: "ebook"
        }
      end
    end
  end

  test "create blocks duplicate for acquired book" do
    book = Book.create!(
      title: "Acquired",
      book_type: :audiobook,
      open_library_work_id: "OL_ACQUIRED_W",
      file_path: "/audiobooks/Author/Acquired"
    )

    assert_no_difference [ "Book.count", "Request.count" ] do
      post requests_path, params: {
        work_id: "OL_ACQUIRED_W",
        title: "Acquired",
        book_type: "audiobook"
      }
    end

    assert_redirected_to search_path
    assert_includes flash[:alert], "already in your library"
  end

  test "destroy cancels pending request" do
    assert_difference "Request.count", -1 do
      delete request_path(@pending_request)
    end
    assert_redirected_to requests_path
    assert_equal "Request cancelled", flash[:notice]
  end

  test "destroy cancels failed request" do
    assert_difference "Request.count", -1 do
      delete request_path(@failed_request)
    end
    assert_redirected_to requests_path
  end

  test "destroy from show page redirects to requests index" do
    assert_difference "Request.count", -1 do
      delete request_path(@pending_request), headers: { "HTTP_REFERER" => request_path(@pending_request) }
    end

    assert_redirected_to requests_path
    assert_equal 303, response.status
  end

  test "destroy from filtered list redirects back to referrer" do
    filtered_requests_path = requests_path(status: "active")

    assert_difference "Request.count", -1 do
      delete request_path(@pending_request), headers: { "HTTP_REFERER" => filtered_requests_path }
    end

    assert_redirected_to filtered_requests_path
    assert_equal 303, response.status
  end

  test "destroy ignores an external referrer" do
    assert_difference "Request.count", -1 do
      delete request_path(@pending_request),
        headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to requests_path
    assert_equal 303, response.status
  end

  test "destroy ignores a malformed referrer after committing cancellation" do
    assert_difference "Request.count", -1 do
      delete request_path(@pending_request),
        headers: { "HTTP_REFERER" => "http://[malformed" }
    end

    assert_redirected_to requests_path
    assert_equal 303, response.status
  end

  test "destroy cleans up orphaned book without requests" do
    book = Book.create!(
      title: "Orphan Book",
      book_type: :ebook,
      open_library_work_id: "OL_ORPHAN_W"
    )
    request = Request.create!(book: book, user: @user, status: :pending)

    assert_difference [ "Request.count", "Book.count" ], -1 do
      delete request_path(request)
    end
  end

  test "destroy preserves an orphaned Book with an acquisition reservation" do
    book = Book.create!(
      title: "Reserved Orphan Book",
      book_type: :ebook,
      acquisition_reservation_token: "upload-reservation",
      acquisition_reservation_owner_type: "Upload",
      acquisition_reservation_owner_id: 91_001
    )
    request = Request.create!(book: book, user: @user, status: :pending)

    assert_difference "Request.count", -1 do
      assert_no_difference "Book.count" do
        delete request_path(request)
      end
    end

    assert Book.exists?(book.id)
    assert book.reload.acquisition_reserved?
  end

  test "destroy keeps a pre-reservation direct acquisition durable for recovery" do
    request, download = create_direct_recovery_request

    assert_no_difference [ "Request.count", "Download.count", "Book.count" ] do
      assert_enqueued_with(job: DirectDownloadRecoveryJob) do
        delete request_path(request)
      end
    end

    assert_redirected_to request_path(request)
    assert request.reload.failed?
    assert download.reload.failed?
    assert_equal "/library/.shelfarr-staging/direct-downloads/test/download", download.direct_staging_path
  end

  test "destroy preserves a reserved direct acquisition and a sibling request" do
    request, download = create_direct_recovery_request
    sibling = Request.create!(book: request.book, user: @admin, status: :pending)
    reserve_direct_book!(request.book, download)

    assert_no_difference [ "Request.count", "Download.count", "Book.count" ] do
      delete request_path(request)
    end

    assert Request.exists?(request.id)
    assert Request.exists?(sibling.id)
    assert download.reload.failed?
    assert request.book.reload.acquisition_reserved?
  end

  test "destroy preserves a published direct acquisition until database finalization" do
    request, download = create_direct_recovery_request
    reserve_direct_book!(request.book, download)
    download.update!(
      direct_destination_path: "/library/author/book.epub",
      direct_book_path: "/library/author",
      direct_output_root: "/library",
      direct_publication_kind: "file",
      direct_content_manifest: '["file",8,"digest"]'
    )

    assert_no_difference [ "Request.count", "Download.count", "Book.count" ] do
      delete request_path(request)
    end

    assert request.reload.failed?
    assert_equal '["file",8,"digest"]', download.reload.direct_content_manifest
    assert request.book.reload.acquisition_reserved?
  end

  test "destroy succeeds when request has download-linked diagnostics" do
    download = @pending_request.downloads.create!(
      name: "Pending Download",
      status: :queued
    )
    RequestEvent.create!(
      request: @pending_request,
      download: download,
      event_type: "dispatch_started",
      source: "DownloadJob",
      level: :info,
      message: "Dispatch started"
    )

    assert_difference "Request.count", -1 do
      delete request_path(@pending_request)
    end

    assert_redirected_to requests_path
  end

  test "destroy preserves a pending ordinary upload until processing finishes" do
    path, size = UploadImportFileService.stage_ingress!(
      StringIO.new("pending request upload"),
      "request-cancel-#{SecureRandom.hex(8)}.epub",
      max_bytes: 1.megabyte
    )
    upload = Upload.create!(
      user: @user,
      request: @pending_request,
      original_filename: "manual.epub",
      file_path: path,
      file_size: size,
      status: :pending
    )

    assert_no_difference [ "Request.count", "Upload.count" ] do
      delete request_path(@pending_request)
    end

    assert_redirected_to request_path(@pending_request)
    assert_match(/upload.*in progress/i, flash[:alert])
    assert Request.exists?(@pending_request.id)
    assert upload.reload.pending?
    assert_equal "pending request upload", File.binread(path)
  ensure
    FileUtils.rm_f(path) if path
  end

  test "destroy takes its cancellation claim before torrent or activity side effects" do
    client = DownloadClient.create!(
      name: "Cancellation side-effect guard #{SecureRandom.hex(4)}",
      client_type: :qbittorrent,
      url: "http://127.0.0.1:8080",
      enabled: true,
      priority: 0
    )
    download = @pending_request.downloads.create!(
      name: "External pending download",
      status: :queued,
      download_client: client,
      external_id: "cancel-side-effect-#{SecureRandom.hex(4)}"
    )
    upload = Upload.create!(
      user: @user,
      request: @pending_request,
      original_filename: "claim-race.epub",
      file_path: "/tmp/claim-race.epub",
      status: :pending
    )
    forbidden_adapter = ->(*) { raise "torrent removal ran before cancellation admission" }

    assert_no_difference -> { ActivityLog.for_action("request.cancelled").count } do
      DownloadClients::Qbittorrent.stub(:new, forbidden_adapter) do
        delete request_path(@pending_request), params: { remove_torrent: "1" }
      end
    end

    assert_redirected_to request_path(@pending_request)
    assert_match(/upload.*in progress/i, flash[:alert])
    assert @pending_request.reload.pending?
    assert download.reload.queued?
    assert upload.reload.pending?
  end

  test "destroy never logs torrent identifiers or raw adapter errors" do
    client = DownloadClient.create!(
      name: "Cancellation log privacy #{SecureRandom.hex(4)}",
      client_type: :qbittorrent,
      url: "http://127.0.0.1:8080",
      enabled: true,
      priority: 0
    )
    private_hash = "private-info-hash-#{SecureRandom.hex(16)}"
    failing_hash = "failing-info-hash-#{SecureRandom.hex(16)}"
    private_error = "private adapter response https://reader:secret@example.test/?token=hidden"
    successful_download = @pending_request.downloads.create!(
      name: "Successful private torrent",
      status: :queued,
      download_client: client,
      external_id: private_hash
    )
    failed_download = @pending_request.downloads.create!(
      name: "Failed private torrent",
      status: :queued,
      download_client: client,
      external_id: failing_hash
    )
    adapter = Object.new
    removed_ids = []
    adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
      removed_ids << external_id
      raise DownloadClients::Base::ConnectionError, private_error if external_id == failing_hash

      true
    end
    messages = []
    logger = Rails.logger
    capture_message = lambda do |*args, &block|
      messages << (args.first || block&.call).to_s
    end

    DownloadClients::Qbittorrent.stub(:new, adapter) do
      logger.stub(:info, capture_message) do
        logger.stub(:warn, capture_message) do
          delete request_path(@pending_request), params: { remove_torrent: "1" }
        end
      end
    end

    assert_redirected_to requests_path
    assert_equal [ private_hash, failing_hash ], removed_ids
    assert messages.any? { |message| message.include?("download ##{successful_download.id}") }
    assert messages.any? { |message| message.include?("download ##{failed_download.id}") }
    assert messages.none? { |message| message.include?(private_hash) }
    assert messages.none? { |message| message.include?(failing_hash) }
    assert messages.none? { |message| message.include?(private_error) }
  end

  test "destroy resumes safely after a durable cancellation claim" do
    book = Book.create!(title: "Claimed cancellation retry", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :downloading)
    download = request.downloads.create!(name: "Claimed cancellation retry", status: :queued)

    request.claim_destructive_cancellation!

    assert request.reload.failed?
    assert_not request.upload_fulfillable?
    assert download.reload.failed?

    assert_difference -> { ActivityLog.for_action("request.cancelled").count }, 1 do
      assert_difference "Request.count", -1 do
        delete request_path(request)
      end
    end

    assert_redirected_to requests_path
    assert_not Request.exists?(request.id)
    assert_not Download.exists?(download.id)
  end

  test "destroy preserves a processing audiobook ZIP and its recovery reservation" do
    root = Dir.mktmpdir("request-cancel-zip-recovery")
    source = File.join(root, "owned-audiobook.zip")
    File.binwrite(source, "complete uploaded ZIP bytes")
    destination = File.join(root, "library", "Author", "Audiobook")
    upload = Upload.create!(
      user: @user,
      request: @pending_request,
      original_filename: "owned-audiobook.zip",
      file_path: source,
      file_size: File.size(source),
      book_type: :audiobook,
      status: :processing,
      destination_path: destination,
      destination_root: File.realpath(root),
      destination_configured_root: root,
      library_path: destination,
      content_sha256: Digest::SHA256.file(source).hexdigest,
      cleanup_source_path: File.realpath(source)
    )

    assert_no_difference [ "Request.count", "Upload.count" ] do
      delete request_path(@pending_request)
    end

    assert_redirected_to request_path(@pending_request)
    assert_match(/upload.*in progress/i, flash[:alert])
    assert Request.exists?(@pending_request.id)
    assert upload.reload.processing?
    assert_equal destination, upload.destination_path
    assert_equal "complete uploaded ZIP bytes", File.binread(source)
  ensure
    FileUtils.rm_rf(root) if root
  end

  test "destroy does not clean up book with file" do
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :pending)

    assert_difference "Request.count", -1 do
      assert_no_difference "Book.count" do
        delete request_path(request)
      end
    end
  end

  test "show displays manual download forms for open request" do
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)

    assert_response :success
    assert_select "form[action='#{manual_magnet_request_path(@pending_request)}']"
    assert_select "input[name='magnet_url']"
    assert_select "form[action='#{manual_nzb_request_path(@pending_request)}']"
    assert_select "input[name='nzb_url'][type='url'][autocomplete='off']"
  end

  test "show hides manual download forms from regular users" do
    get request_path(@pending_request)

    assert_response :success
    assert_select "form[action='#{manual_magnet_request_path(@pending_request)}']", count: 0
    assert_select "form[action='#{manual_nzb_request_path(@pending_request)}']", count: 0
  end

  test "show hides manual download forms for completed request" do
    @pending_request.complete!
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)

    assert_response :success
    assert_select "form[action='#{manual_magnet_request_path(@pending_request)}']", count: 0
    assert_select "form[action='#{manual_nzb_request_path(@pending_request)}']", count: 0
  end

  test "show hides manual download forms for processing request" do
    @pending_request.update!(status: :processing)
    sign_out
    sign_in_as(@admin)

    get request_path(@pending_request)

    assert_response :success
    assert_select "form[action='#{manual_magnet_request_path(@pending_request)}']", count: 0
    assert_select "form[action='#{manual_nzb_request_path(@pending_request)}']", count: 0
  end

  test "manual magnet creates selected result and queues download" do
    sign_out
    sign_in_as(@admin)
    magnet = " magnet:?xt=urn:btih:#{'a' * 40}&dn=Manual+Book "

    assert_enqueued_with(job: DownloadJob) do
      assert_difference [ "SearchResult.count", "Download.count" ], 1 do
        post manual_magnet_request_path(@pending_request), params: { magnet_url: magnet }
      end
    end

    @pending_request.reload
    result = @pending_request.search_results.find_by(source: SearchResult::SOURCE_MANUAL_MAGNET)
    download = @pending_request.downloads.order(:created_at).last

    assert @pending_request.downloading?
    assert result.selected?
    assert_equal "magnet:?xt=urn:btih:#{'a' * 40}&dn=Manual+Book", result.magnet_url
    assert_equal result, download.search_result
    assert_equal "Magnet link queued for download.", flash[:notice]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual magnet rejects invalid link" do
    sign_out
    sign_in_as(@admin)

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_magnet_request_path(@pending_request), params: { magnet_url: "https://example.com/file.torrent" }
    end

    assert_equal "Enter a valid magnet link", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual magnet rejects processing request" do
    @pending_request.update!(status: :processing)
    sign_out
    sign_in_as(@admin)

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_magnet_request_path(@pending_request), params: { magnet_url: "magnet:?xt=urn:btih:#{'d' * 40}" }
    end

    assert_equal "Cannot add a magnet link while post-processing is active", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual magnet redirects when duplicate result save races" do
    sign_out
    sign_in_as(@admin)

    request = @pending_request
    request.define_singleton_method(:add_manual_magnet!) do |_magnet_url|
      raise ActiveRecord::RecordNotUnique, "duplicate"
    end
    finder = Object.new
    finder.define_singleton_method(:find) { |_id| request }

    Request.stub(:includes, finder) do
      post manual_magnet_request_path(@pending_request), params: { magnet_url: "magnet:?xt=urn:btih:#{'f' * 40}" }
    end

    assert_equal "Magnet link could not be queued. Please try again.", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual magnet cannot be added by regular users" do
    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_magnet_request_path(@pending_request), params: { magnet_url: "magnet:?xt=urn:btih:#{'b' * 40}" }
    end

    assert_equal "You don't have permission to add magnet links", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual magnet cannot be added to another user's request" do
    other_request = Request.create!(book: books(:ebook_pending), user: @admin, status: :pending)

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_magnet_request_path(other_request), params: { magnet_url: "magnet:?xt=urn:btih:#{'c' * 40}" }
    end

    assert_response :not_found
  end

  test "manual NZB creates selected result and queues download" do
    sign_out
    sign_in_as(@admin)
    url = "https://downloads.example/release/123?X-Amz-Signature=very-secret"

    assert_enqueued_with(job: DownloadJob) do
      assert_difference [ "SearchResult.count", "Download.count" ], 1 do
        post manual_nzb_request_path(@pending_request), params: { nzb_url: "  #{url}  " }
      end
    end

    @pending_request.reload
    result = @pending_request.search_results.find_by!(source: SearchResult::SOURCE_MANUAL_NZB)
    download = @pending_request.downloads.order(:created_at).last

    assert @pending_request.downloading?
    assert result.selected?
    assert result.usenet?
    assert_equal url, result.download_url
    assert_equal result, download.search_result
    assert_equal "NZB URL queued for download.", flash[:notice]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual NZB rejects invalid URL" do
    sign_out
    sign_in_as(@admin)

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_nzb_request_path(@pending_request), params: { nzb_url: "file:///tmp/book.nzb" }
    end

    assert_equal "Enter a valid HTTP(S) NZB URL", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual NZB redirects when duplicate result save races" do
    sign_out
    sign_in_as(@admin)

    request = @pending_request
    request.define_singleton_method(:add_manual_nzb!) do |_nzb_url|
      raise ActiveRecord::RecordNotUnique, "duplicate"
    end
    finder = Object.new
    finder.define_singleton_method(:find) { |_id| request }

    Request.stub(:includes, finder) do
      post manual_nzb_request_path(@pending_request), params: { nzb_url: "https://downloads.example/book.nzb" }
    end

    assert_equal "NZB URL could not be queued. Please try again.", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual NZB cannot be added by regular users" do
    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_nzb_request_path(@pending_request), params: { nzb_url: "https://downloads.example/book.nzb" }
    end

    assert_equal "You don't have permission to add NZB URLs", flash[:alert]
    assert_redirected_to request_path(@pending_request)
  end

  test "manual NZB cannot be added to another user's request" do
    other_request = Request.create!(book: books(:ebook_pending), user: @admin, status: :pending)

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      post manual_nzb_request_path(other_request), params: { nzb_url: "https://downloads.example/book.nzb" }
    end

    assert_response :not_found
  end

  test "destroy rejects non-cancellable status" do
    # Only completed requests cannot be cancelled
    @pending_request.update!(status: :completed)

    assert_no_difference "Request.count" do
      delete request_path(@pending_request)
    end

    assert_redirected_to request_path(@pending_request)
    assert_includes flash[:alert], "Cannot cancel"
  end

  test "user cannot cancel another user's request" do
    other_user = users(:two)
    other_request = Request.create!(
      book: books(:ebook_pending),
      user: other_user,
      status: :pending
    )

    delete request_path(other_request)
    assert_response :not_found
  end

  # Retry tests
  test "retry requires admin" do
    # Regular user should be rejected
    post retry_request_path(@failed_request)

    assert_response :redirect
    assert_equal "You don't have permission to retry requests", flash[:alert]
  end

  test "admin can retry a request" do
    sign_out
    sign_in_as(@admin)

    @failed_request.update!(attention_needed: true, issue_description: "Test issue")

    post retry_request_path(@failed_request)

    @failed_request.reload
    assert @failed_request.pending?
    assert_not @failed_request.attention_needed?
    assert_nil @failed_request.issue_description
    assert_equal "Request has been queued for retry.", flash[:notice]
  end

  test "post-processing retry reports durable watchdog recovery when enqueue fails" do
    sign_out
    sign_in_as(@admin)
    request = Request.create!(
      book: books(:audiobook_acquired),
      user: @user,
      status: :processing,
      attention_needed: true,
      issue_description: "Post-processing failed"
    )
    download = request.downloads.create!(
      name: "Finished",
      status: :completed,
      post_processing_job_id: "failed-request-retry-owner"
    )
    failed_job = PostProcessingJob.new(0)

    PostProcessingJob.stub(:new, failed_job) do
      failed_job.stub(:enqueue, false) do
        post retry_request_path(request)
      end
    end

    assert_redirected_to request_path(request)
    assert_match(/watchdog will retry it automatically/i, flash[:alert])
    assert_not request.reload.attention_needed?
    assert_equal failed_job.job_id, download.reload.post_processing_job_id
  end

  test "retry redirects back to referring page" do
    sign_out
    sign_in_as(@admin)

    # Set referer header to simulate coming from requests index
    post retry_request_path(@failed_request), headers: { "HTTP_REFERER" => requests_path }

    assert_redirected_to requests_path
  end

  test "retry falls back safely after committing for hostile referrers" do
    sign_out
    sign_in_as(@admin)

    [ "https://attacker.example/phishing", "http://[malformed" ].each_with_index do |referer, index|
      book = Book.create!(title: "Safe retry redirect #{index}", book_type: :ebook)
      request = Request.create!(book: book, user: @user, status: :failed)

      post retry_request_path(request), headers: { "HTTP_REFERER" => referer }

      assert_redirected_to request_path(request)
      assert request.reload.pending?
    end
  end

  # Download tests
  test "download requires authentication" do
    sign_out
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :redirect
  end

  test "download redirects if book not acquired" do
    request = @pending_request
    assert_not request.book.acquired?

    get download_request_path(request)
    assert_redirected_to library_index_path
    assert_equal "This book is not available for download", flash[:alert]
  end

  test "download redirects if file not found" do
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_redirected_to request_path(request)
    assert_equal "File not found on server", flash[:alert]
  end

  test "download sends single file" do
    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test_audiobook.m4b")
    File.write(temp_file, "test audio content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Test Download",
      author: "Test Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :success
    assert_equal "audio/mp4", response.content_type
    assert_match /attachment/, response.headers["Content-Disposition"]
    assert_match /test_audiobook\.m4b/, response.headers["Content-Disposition"]
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "download sends zipped directory" do
    temp_dir = Dir.mktmpdir
    book_dir = File.join(temp_dir, "Test Author", "Test Book")
    FileUtils.mkdir_p(book_dir)
    File.write(File.join(book_dir, "part1.m4b"), "audio part 1")
    File.write(File.join(book_dir, "part2.m4b"), "audio part 2")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Test Book",
      author: "Test Author",
      book_type: :audiobook,
      file_path: book_dir
    )
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_response :success
    assert_equal "application/zip", response.content_type
    assert_match /attachment/, response.headers["Content-Disposition"]
    assert_match /Test Author - Test Book\.zip/, response.headers["Content-Disposition"]
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "download refuses to zip the output root for flat-imported books" do
    temp_dir = Dir.mktmpdir
    File.write(File.join(temp_dir, "book-a.m4b"), "audio a")
    File.write(File.join(temp_dir, "book-b.m4b"), "audio b")

    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Flat Book",
      author: "Test Author",
      book_type: :audiobook,
      file_path: temp_dir
    )
    request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(request)
    assert_redirected_to request_path(request)
    assert flash[:alert].present?
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "user can download another user's request when book is acquired" do
    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test.m4b")
    File.write(temp_file, "content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "Other User Book",
      author: "Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    other_request = Request.create!(book: book, user: @admin, status: :completed)

    # Users can download any acquired book, regardless of who requested it
    get download_request_path(other_request)
    assert_response :success
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  test "admin can download any user's request" do
    sign_out
    sign_in_as(@admin)

    temp_dir = Dir.mktmpdir
    temp_file = File.join(temp_dir, "test.m4b")
    File.write(temp_file, "content")

    # Set output path to temp dir for path validation
    SettingsService.set(:audiobook_output_path, temp_dir)

    book = Book.create!(
      title: "User Book",
      author: "Author",
      book_type: :audiobook,
      file_path: temp_file
    )
    user_request = Request.create!(book: book, user: @user, status: :completed)

    get download_request_path(user_request)
    assert_response :success
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  private

  def create_direct_recovery_request
    book = Book.create!(title: "Direct Cancellation", author: "Safety Author", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :downloading)
    download = request.downloads.create!(
      name: "Direct Cancellation",
      status: :downloading,
      download_type: "direct",
      direct_staging_path: "/library/.shelfarr-staging/direct-downloads/test/download"
    )
    [ request, download ]
  end

  def reserve_direct_book!(book, download)
    token = SecureRandom.hex(32)
    book.update!(
      acquisition_reservation_token: token,
      acquisition_reservation_owner_type: "Download",
      acquisition_reservation_owner_id: download.id
    )
    download.update!(direct_reservation_token: token)
  end

  def create_store_offer
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    @pending_request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "347175270",
      title: "The Pending Ebook",
      author: "Another Author",
      isbns: [ "9781480484160" ],
      language: "en",
      formats: [ "epub" ],
      market: "PT",
      drm_free: true,
      drm_type: "Watermarked",
      price_amount: BigDecimal("7.41"),
      price_currency: "EUR",
      localized_price: "7,41 €",
      storefront_url: "https://www.ebooks.com/en-pt/book/347175270/the-pending-ebook/another-author/",
      quoted_at: Time.current
    )
  end
end
