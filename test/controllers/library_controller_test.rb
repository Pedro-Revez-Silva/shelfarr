# frozen_string_literal: true

require "test_helper"

class LibraryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @admin = users(:two)
    @acquired_audiobook = books(:audiobook_acquired)
    sign_in_as(@user)
  end

  test "index requires authentication" do
    sign_out
    get library_index_path
    assert_response :redirect
  end

  test "index shows acquired books" do
    @acquired_audiobook.update!(cover_url: "https://covers.example.test/private-cover.jpg")

    get library_index_path
    assert_response :success
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_select "h1", "Library"
    assert_select "a[href='#{library_path(@acquired_audiobook)}']"
    assert_select "[data-library-card][data-library-source='shelfarr'][class~='motion-reduce:transition-none'][class~='motion-reduce:hover:scale-100']"
    assert_select "img[src='https://covers.example.test/private-cover.jpg'][referrerpolicy='no-referrer']"
  end

  test "admin library shows purchased Audible titles without creating placeholder books" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Owned Audible Title",
      authors: [ "Audible Author" ],
      ownership_type: "purchased"
    )

    assert_no_difference -> { Book.count } do
      get library_index_path
    end

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control", ""), "no-store"
    assert_select "#library-catalog"
    assert_select "[data-library-card][data-library-source='audible'][data-owned-library-item-id='#{item.id}']" do
      assert_select "[class~='motion-reduce:transition-none'][class~='motion-reduce:hover:scale-100']"
      assert_select "h3", text: "Owned Audible Title"
      assert_select "span", text: "Audible"
      assert_select "span", text: "Audio"
      assert_select "form[action='#{backup_item_admin_owned_library_connection_path(connection, item_id: item.id)}']"
    end
    assert_select "turbo-cable-stream-source", minimum: 1
  end

  test "regular users do not see the personal Audible purchase catalog" do
    connection = create_audible_connection
    connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Private Audible Purchase",
      ownership_type: "purchased"
    )

    OwnedLibraryBookMatcher.stub(:new, ->(*) { flunk "regular Library view should not build an Audible matcher" }) do
      get library_index_path
    end

    assert_response :success
    assert_select "[data-library-card][data-library-source='audible']", count: 0
    assert_select "body", text: /Private Audible Purchase/, count: 0
    assert_select "a[href='#{library_index_path(source: :audible)}']", text: "Audible"

    get library_index_path(source: "audible")

    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 0
    assert_select "h3", "No titles match these filters"
    assert_select "body", text: /Private Audible Purchase/, count: 0
  end

  test "linked Audible title renders once as the canonical acquired card" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Already Imported",
      ownership_type: "purchased",
      book: @acquired_audiobook
    )

    get library_index_path

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}']", count: 0
    assert_select "[data-library-card][data-library-source='shelfarr'] a[href='#{library_path(@acquired_audiobook)}']", count: 1 do
      assert_select "span", text: "On server"
      assert_select "span", text: "Audible"
    end
  end

  test "Audible filter shows only cards carrying the Audible tag" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    audible_only = connection.owned_library_items.create!(
      external_id: "B012345680",
      title: "Audible Filter Cloud Title",
      ownership_type: "purchased"
    )
    linked_book = Book.create!(
      title: "Audible Filter Local Title",
      author: "Tagged Author",
      book_type: :audiobook,
      file_path: "/audiobooks/audible-filter-local"
    )
    connection.owned_library_items.create!(
      external_id: "B012345681",
      title: linked_book.title,
      ownership_type: "purchased",
      book: linked_book
    )
    untagged_book = Book.create!(
      title: "Audible Filter Untagged Title",
      author: "Local Author",
      book_type: :audiobook,
      file_path: "/audiobooks/audible-filter-untagged"
    )

    get library_index_path(source: "audible")

    assert_response :success
    assert_select "a[href='#{library_index_path(source: :audible)}']", text: "Audible" do |links|
      assert_includes links.first["class"], "bg-orange-600"
    end
    assert_select "input[name='source'][value='audible']"
    assert_select "#library-catalog [data-library-card]", count: 2
    assert_select "[data-owned-library-item-id='#{audible_only.id}']", count: 1
    assert_select "[data-library-book-id='#{linked_book.id}']", count: 1
    assert_select "[data-library-book-id='#{untagged_book.id}']", count: 0
    assert_select "span", text: "2 titles"
    css_select("#library-catalog [data-library-card]").each do |card|
      assert card.css("span").any? { |badge| badge.text.strip == "Audible" }
    end
  end

  test "an ambiguous same-title audiobook offers a separate backup instead of overwriting" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    local_book = Book.create!(
      title: "A Shared Title",
      author: "A Shared Author",
      narrator: "A Shared Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/shared-title"
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: local_book.title,
      authors: [ local_book.author ],
      narrators: [ local_book.narrator ],
      ownership_type: "purchased"
    )

    get library_index_path

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}']", text: /Possible local-library match/
    assert_select "#library-catalog [data-library-card] h3", text: "A Shared Title", count: 2
    assert_select "[data-owned-library-item-id='#{item.id}'] form[action*='separate_edition=1']" do
      assert_select "button", text: "Back up separately"
      assert_select "button[disabled]", count: 0
    end
  end

  test "stable identifier matches collapse into one tagged local card" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    local_book = Book.create!(
      title: "Identifier Dedup Local",
      author: "Local Author",
      isbn: "9781234567897",
      book_type: :audiobook,
      file_path: "/audiobooks/identifier-dedup"
    )
    LibraryItem.create!(
      library_platform: SettingsService.active_library_platform,
      library_id: "library-dedup",
      audiobookshelf_id: "item-dedup",
      asin: "B-0123 45678!",
      isbn: "978-1-2345-6789-7"
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Identifier Dedup Audible Metadata",
      authors: [ "Audible Author" ],
      ownership_type: "purchased"
    )

    get library_index_path(source: "audible", q: "Identifier Dedup")

    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 1
    assert_select "[data-owned-library-item-id='#{item.id}']", count: 0
    assert_select "[data-library-book-id='#{local_book.id}']" do
      assert_select "span", text: "On server"
      assert_select "span", text: "Audible"
    end
    assert_select "input[name='source'][value='audible']"
    assert_select "a[href='#{library_index_path(source: :audible)}']", text: "Clear"
    assert_select "a[href='#{library_index_path(source: :audible, q: 'Identifier Dedup')}']", text: "Audible"
  end

  test "unified catalog paginates all audiobook sources together" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    Book.create!(
      title: "Aardvark Local Audiobook",
      author: "Local Author",
      book_type: :audiobook,
      file_path: "/audiobooks/aardvark-local"
    )
    51.times do |index|
      connection.owned_library_items.create!(
        external_id: format("B%09d", index),
        title: format("Audible %02d", index),
        ownership_type: "purchased"
      )
    end

    get library_index_path(type: "audiobook")
    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 50
    assert_select "#library-catalog [data-library-source='shelfarr']", minimum: 1
    assert_select "#library-catalog [data-library-source='audible']", minimum: 1
    assert_select "a[href*='page=2']", text: "Next"

    get library_index_path(source: "audible")
    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 50
    assert_select "#library-catalog [data-library-source='shelfarr']", count: 0
    assert_select "a[href*='source=audible'][href*='page=2']", text: "Next"

    get library_index_path(source: "audible", page: 2)
    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 1

    get library_index_path(type: "ebook")
    assert_response :success
    assert_select "[data-library-source='audible']", count: 0
  end

  test "unified catalog interleaves local and Audible cards alphabetically" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Unified Sort Alpha",
      ownership_type: "purchased"
    )
    Book.create!(
      title: "Unified Sort Bravo",
      author: "Local Author",
      book_type: :audiobook,
      file_path: "/audiobooks/unified-sort-bravo"
    )
    connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "Unified Sort Charlie",
      ownership_type: "purchased"
    )

    get library_index_path(q: "Unified Sort")

    assert_response :success
    titles = css_select("#library-catalog [data-library-card] h3").map { |node| node.text.strip }
    assert_equal [ "Unified Sort Alpha", "Unified Sort Bravo", "Unified Sort Charlie" ], titles
  end

  test "catalog search treats SQL wildcard characters as literal text" do
    literal = Book.create!(
      title: "A 100% Literal Catalog Title",
      book_type: :audiobook,
      file_path: "/audiobooks/literal-percent"
    )
    Book.create!(
      title: "A 1000 Literal Catalog Title",
      book_type: :audiobook,
      file_path: "/audiobooks/no-percent"
    )

    get library_index_path(q: "100% Literal")

    assert_response :success
    assert_select "[data-library-book-id='#{literal.id}']", count: 1
    assert_select "#library-catalog [data-library-card]", count: 1
  end

  test "unified catalog pagination has no source-specific gaps or duplicates" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    30.times do |index|
      Book.create!(
        title: format("Pagination Mix %02d Local", index),
        author: "Local Author",
        book_type: :audiobook,
        file_path: "/audiobooks/pagination-mix-#{index}"
      )
      connection.owned_library_items.create!(
        external_id: format("B%09d", index),
        title: format("Pagination Mix %02d Audible", index),
        ownership_type: "purchased"
      )
    end

    get library_index_path(q: "Pagination Mix", type: "audiobook")
    assert_response :success
    first_page_keys = catalog_card_keys
    assert_equal 50, first_page_keys.length

    get library_index_path(q: "Pagination Mix", type: "audiobook", page: 2)
    assert_response :success
    second_page_keys = catalog_card_keys
    assert_equal 10, second_page_keys.length
    assert_empty first_page_keys & second_page_keys
    assert_equal 60, (first_page_keys | second_page_keys).length
  end

  test "large unified catalog only instantiates the requested page" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    now = Time.current
    book_rows = 1_000.times.map do |index|
      {
        title: format("Scale Catalog %04d Local", index),
        author: "Local Author",
        book_type: Book.book_types.fetch("audiobook"),
        file_path: format("/audiobooks/scale-catalog-%04d", index),
        created_at: now,
        updated_at: now
      }
    end
    owned_rows = 1_000.times.map do |index|
      {
        owned_library_connection_id: connection.id,
        external_id: format("S%09d", index),
        title: format("Scale Catalog %04d Audible", index),
        authors: [ "Audible Author" ],
        narrators: [],
        media_type: "audiobook",
        ownership_type: "purchased",
        active: true,
        downloaded: false,
        provider_metadata: {},
        created_at: now,
        updated_at: now
      }
    end
    Book.insert_all!(book_rows)
    OwnedLibraryItem.insert_all!(owned_rows)

    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      if payload[:class_name].in?(%w[Book OwnedLibraryItem])
        instantiated += payload[:record_count]
      end
    end
    get library_index_path(q: "Scale Catalog", type: "audiobook", page: 40)

    assert_response :success
    assert_select "#library-catalog [data-library-card]", count: 50
    assert_select "p", text: /2000 titles · Page 40 of 40/
    assert_operator instantiated, :<=, 150,
      "a catalog page should not instantiate records from preceding pages"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "Audible catalog only instantiates the latest import for a visible title" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Import History Scale Title",
      ownership_type: "purchased"
    )
    now = Time.current
    import_rows = 500.times.map do |index|
      {
        owned_library_item_id: item.id,
        status: "failed",
        error_message: "historic failure #{index}",
        automatic: false,
        companion_start_attempts: 0,
        separate_edition: false,
        upload_recovery_attempts: 0,
        created_at: now - (500 - index).seconds,
        updated_at: now - (500 - index).seconds
      }
    end
    latest = import_rows.last.merge(
      error_message: "latest bounded failure",
      created_at: now,
      updated_at: now
    )
    OwnedMediaImport.insert_all!(import_rows << latest)

    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      instantiated += payload[:record_count] if payload[:class_name] == "OwnedMediaImport"
    end

    get library_index_path(q: "Import History Scale Title")

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}']", text: /latest bounded failure/
    assert_operator instantiated, :<=, 1,
      "a catalog card should not instantiate the title's complete import history"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "local catalog cards do not instantiate every linked Audible ownership row" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    book = Book.create!(
      title: "Linked Ownership Scale Title",
      author: "Scale Author",
      book_type: :audiobook,
      file_path: "/audiobooks/linked-ownership-scale"
    )
    now = Time.current
    rows = 500.times.map do |index|
      {
        owned_library_connection_id: connection.id,
        book_id: book.id,
        external_id: format("L%09d", index),
        title: book.title,
        authors: [ book.author ],
        narrators: [],
        media_type: "audiobook",
        ownership_type: "purchased",
        active: true,
        downloaded: true,
        provider_metadata: {},
        created_at: now,
        updated_at: now
      }
    end
    OwnedLibraryItem.insert_all!(rows)

    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      instantiated += payload[:record_count] if payload[:class_name] == "OwnedLibraryItem"
    end

    get library_index_path(q: "Linked Ownership Scale Title")

    assert_response :success
    assert_select "[data-library-book-id='#{book.id}'] span", text: "Audible"
    assert_equal 0, instantiated,
      "a local card should use its projected Audible tag instead of hydrating ownership history"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "invalid type behaves like the unified All catalog" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Invalid Type Audible",
      ownership_type: "purchased"
    )

    get library_index_path(type: "not-a-real-type", q: "Invalid Type Audible")

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}']", count: 1
    assert_select "a[href='#{library_index_path(q: 'Invalid Type Audible')}']", text: "All"
  end

  test "invalid source behaves like the unified All catalog" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345689",
      title: "Invalid Source Audible",
      ownership_type: "purchased"
    )

    get library_index_path(source: "not-a-real-source", q: "Invalid Source Audible")

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}']", count: 1
    assert_select "a[href='#{library_index_path(q: 'Invalid Source Audible')}']", text: "All" do |links|
      assert_includes links.first["class"], "bg-white"
    end
  end

  test "Audible library summarizes backups queued across different titles" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    statuses = %w[queued downloading processing]
    statuses.each_with_index do |status, index|
      item = connection.owned_library_items.create!(
        external_id: format("B%09d", index),
        title: "Queued Audible #{index}",
        ownership_type: "purchased"
      )
      item.owned_media_imports.create!(requested_by: @admin, status: status)
    end

    get library_index_path

    assert_response :success
    assert_select "#audible-backup-queue", text: /3 backup tasks queued or active/
    assert_select "#audible-backup-queue", text: /1 waiting · 1 backing up · 1 importing/
  end

  test "Audible library shows a passive existing-library batch item without making it manually queueable" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B098765431",
      title: "Waiting Existing Purchase",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @admin,
      status: "pending",
      automatic: true
    )

    get library_index_path

    assert_response :success
    assert_select "#audible-backup-queue", text: /1 waiting in confirmed batch/
    assert_select "[data-owned-library-item-id='#{item.id}'][data-backup-origin='backlog']" do
      assert_select "p", text: "Waiting in existing-library batch"
      assert_select "button[disabled]", text: "Waiting in batch…"
    end
  end

  test "Audible card identifies an automatically queued backup" do
    sign_out
    sign_in_as(@admin)
    connection = create_audible_connection
    item = connection.owned_library_items.create!(
      external_id: "B098765432",
      title: "Automatically Queued Audible",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: @admin,
      status: "queued",
      automatic: true
    )

    get library_index_path

    assert_response :success
    assert_select "[data-owned-library-item-id='#{item.id}'][data-backup-origin='automatic']" do
      assert_select "p", text: "Automatically queued"
    end
  end

  test "index filters by audiobook type" do
    get library_index_path(type: "audiobook")
    assert_response :success
    assert_select "a[href='#{library_path(@acquired_audiobook)}']"
  end

  test "index filters by ebook type" do
    ebook = Book.create!(
      title: "Acquired Ebook",
      author: "Test Author",
      book_type: :ebook,
      file_path: "/ebooks/Test Author/Acquired Ebook"
    )

    OwnedLibraryBookMatcher.stub(:new, ->(*) { flunk "ebook-only Library view should not build an Audible matcher" }) do
      get library_index_path(type: "ebook")
    end
    assert_response :success
    assert_select "a[href='#{library_path(ebook)}']"
  end

  test "index shows empty state when no books" do
    Book.where.not(file_path: nil).update_all(file_path: nil)

    get library_index_path
    assert_response :success
    assert_select "h3", "Your library is empty"
  end

  test "type-only empty result is presented as a filtered state" do
    Book.where.not(file_path: nil).update_all(file_path: nil)

    get library_index_path(type: "ebook")

    assert_response :success
    assert_select "h3", "No titles match these filters"
    assert_select "h3", text: "Your library is empty", count: 0
  end

  test "show displays book details" do
    @acquired_audiobook.update!(cover_url: "https://covers.example.test/private-cover.jpg")

    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "h1", @acquired_audiobook.title
    assert_select "img[src='https://covers.example.test/private-cover.jpg'][referrerpolicy='no-referrer']"
  end

  test "show returns 404 for non-acquired book" do
    pending_book = books(:ebook_pending)

    get library_path(pending_book)
    assert_response :not_found
  end

  test "show displays download button when user has request" do
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :completed
    )

    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "a[href='#{download_request_path(request)}']", text: /Download/
  end

  test "show does not display download button when user has no request" do
    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "a[href*='download']", false
  end

  test "show displays file path for admin" do
    sign_out
    sign_in_as(@admin)

    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "code", @acquired_audiobook.file_path
  end

  test "show does not display file path for regular user" do
    get library_path(@acquired_audiobook)
    assert_response :success
    assert_select "code", false
  end

  test "retry post processing requires admin" do
    post retry_post_processing_library_path(@acquired_audiobook)

    assert_redirected_to library_index_path
    assert_equal "Only admins can retry post-processing", flash[:alert]
  end

  test "retry post processing redirects when no retryable download exists" do
    sign_out
    sign_in_as(@admin)

    post retry_post_processing_library_path(@acquired_audiobook)

    assert_redirected_to library_path(@acquired_audiobook)
    assert_equal "No retryable post-processing found for this book", flash[:alert]
  end

  test "retry post processing clears attention and queues job" do
    sign_out
    sign_in_as(@admin)
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :processing,
      attention_needed: true,
      issue_description: "Post-processing failed"
    )
    download = request.downloads.create!(
      name: "Finished",
      status: :completed,
      post_processing_job_id: "failed-job-id"
    )

    retry_args = ->(args) { args == [ download.id, 0, "failed-job-id" ] }
    retry_job = assert_enqueued_with(job: PostProcessingJob, args: retry_args) do
      post retry_post_processing_library_path(@acquired_audiobook),
        headers: { "HTTP_REFERER" => "http://[malformed" }
    end

    assert_redirected_to library_path(@acquired_audiobook)
    assert_equal "Post-processing has been queued for retry.", flash[:notice]
    assert_not request.reload.attention_needed?
    assert_nil request.issue_description
    assert_equal retry_job.job_id, download.reload.post_processing_job_id
  end

  test "retry post processing keeps a watchdog-recoverable owner when enqueue fails" do
    sign_out
    sign_in_as(@admin)
    request = Request.create!(
      book: @acquired_audiobook,
      user: @user,
      status: :processing,
      attention_needed: true,
      issue_description: "Post-processing failed"
    )
    download = request.downloads.create!(
      name: "Finished",
      status: :completed,
      post_processing_job_id: "failed-enqueue-owner"
    )
    failed_job = PostProcessingJob.new(0)

    PostProcessingJob.stub(:new, failed_job) do
      failed_job.stub(:enqueue, false) do
        post retry_post_processing_library_path(@acquired_audiobook)
      end
    end

    assert_redirected_to library_path(@acquired_audiobook)
    assert_match(/watchdog will retry it automatically/i, flash[:alert])
    assert_not request.reload.attention_needed?
    assert_nil request.issue_description
    assert_equal failed_job.job_id, download.reload.post_processing_job_id
  end

  test "destroy requires admin" do
    delete library_path(@acquired_audiobook)

    assert_redirected_to library_index_path
    assert_equal "Only admins can delete books from the library", flash[:alert]
    assert Book.exists?(@acquired_audiobook.id)
  end

  test "destroy removes book and associated requests" do
    sign_out
    sign_in_as(@admin)
    Request.create!(book: @acquired_audiobook, user: @user, status: :completed)

    assert_difference -> { Book.count }, -1 do
      delete library_path(@acquired_audiobook),
        headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to library_index_path
    assert_equal "\"#{@acquired_audiobook.title}\" has been removed from the library", flash[:notice]
    assert_empty Request.where(book_id: @acquired_audiobook.id)
  end

  test "destroy preserves library bytes and records while a request upload is pending" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-blocked-upload") do |dir|
      file_path = File.join(dir, "book.epub")
      File.binwrite(file_path, "keep library bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Blocked Upload Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: file_path
      )
      request = Request.create!(book: book, user: @user, status: :pending)
      upload = Upload.create!(
        user: @user,
        request: request,
        original_filename: "pending.epub",
        file_path: "/tmp/pending-library-delete.epub",
        status: :pending
      )

      assert_no_difference [ "Book.count", "Request.count", "Upload.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/upload or direct acquisition in progress/i, flash[:alert])
      assert_equal "keep library bytes", File.binread(file_path)
      assert Request.exists?(request.id)
      assert Upload.exists?(upload.id)
    end
  end

  test "destroy preserves a direct-download recovery owner" do
    sign_out
    sign_in_as(@admin)
    book = Book.create!(
      title: "Blocked Direct Ebook",
      author: "Test Author",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :downloading)
    download = request.downloads.create!(
      name: "Blocked Direct Ebook",
      status: :downloading,
      download_type: "direct",
      direct_staging_path: "/ebooks/.shelfarr-staging/direct-downloads/test/download",
      direct_staging_device: 12,
      direct_staging_inode: 34
    )

    assert_no_difference [ "Book.count", "Request.count", "Download.count" ] do
      delete library_path(book)
    end

    assert_redirected_to library_path(book)
    assert_match(/upload or direct acquisition in progress/i, flash[:alert])
    assert Request.exists?(request.id)
    assert Download.exists?(download.id)
  end

  test "destroy preserves a recoverable post-processing owner and library bytes" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-post-processing") do |dir|
      file_path = File.join(dir, "partial.epub")
      File.binwrite(file_path, "recoverable post-processing bytes")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Recoverable post-processing book",
        book_type: :ebook,
        file_path: file_path
      )
      request = Request.create!(book: book, user: @user, status: :processing)
      download = request.downloads.create!(
        name: book.title,
        status: :completed,
        post_processing_job_id: "library-delete-post-processing-owner"
      )

      assert_no_difference [ "Book.count", "Request.count", "Download.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/post-processing import awaiting recovery/i, flash[:alert])
      assert_equal "recoverable post-processing bytes", File.binread(file_path)
      assert Request.exists?(request.id)
      assert Download.exists?(download.id)
    end
  end

  test "destroy preserves a requestless active Audible import reached through its completed upload" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-blocked-owned") do |dir|
      owned_file_path = File.join(dir, "Owned Title.m4b")
      File.binwrite(owned_file_path, "keep owned audio")
      SettingsService.set(:audiobook_output_path, dir)
      book = Book.create!(
        title: "Owned Active Title",
        author: "Audible Author",
        book_type: :audiobook,
        file_path: owned_file_path
      )
      upload = Upload.create!(
        user: @admin,
        book: book,
        original_filename: "Owned Title.m4b",
        file_path: owned_file_path,
        file_size: File.size(owned_file_path),
        status: :completed
      )
      connection = create_audible_connection
      item = connection.owned_library_items.create!(
        external_id: "B0LIBRARY#{SecureRandom.hex(2).upcase}",
        title: book.title,
        ownership_type: "purchased"
      )
      media_import = item.owned_media_imports.create!(
        upload: upload,
        requested_by: @admin,
        status: "processing",
        destination_path: owned_file_path,
        library_path: owned_file_path
      )

      assert_no_difference [ "Book.count", "Upload.count", "OwnedMediaImport.count" ] do
        delete library_path(book), params: { delete_files: "1" }
      end

      assert_redirected_to library_path(book)
      assert_match(/upload or direct acquisition in progress/i, flash[:alert])
      assert_equal "keep owned audio", File.binread(owned_file_path)
      assert_equal book, upload.reload.book
      assert_equal upload, media_import.reload.upload
    end
  end

  test "destroy deletes file inside configured output directory" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      file_path = File.join(dir, "book.epub")
      File.write(file_path, "book")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Temporary Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: file_path
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path
      assert_not File.exist?(file_path)
      assert_not Book.exists?(book.id)
    end
  end

  test "destroy does not delete file outside configured output directories" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      file_path = File.join(dir, "outside.epub")
      File.write(file_path, "book")
      SettingsService.set(:ebook_output_path, File.join(dir, "allowed"))
      book = Book.create!(
        title: "Outside Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: file_path
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_path(book)
      assert File.exist?(file_path)
      assert Book.exists?(book.id)
      assert_match(/record was kept/, flash[:alert])
    end
  end

  test "destroy does not delete the output root when a flat-imported book points at it" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-test") do |dir|
      other_book_file = File.join(dir, "other-book.epub")
      File.write(other_book_file, "book")
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Flat Ebook",
        author: "Test Author",
        book_type: :ebook,
        file_path: dir
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_path(book)
      assert File.directory?(dir)
      assert File.exist?(other_book_file)
      assert Book.exists?(book.id)
      assert_match(/record was kept/, flash[:alert])
    end
  end

  test "destroy safely removes a nested library directory" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-tree") do |root|
      library_path = File.join(root, "Author", "Title")
      FileUtils.mkdir_p(File.join(library_path, "disc"))
      File.binwrite(File.join(library_path, "book.m4b"), "audio")
      File.binwrite(File.join(library_path, "disc", "chapter.mp3"), "chapter")
      SettingsService.set(:audiobook_output_path, root)
      book = Book.create!(
        title: "Nested Audiobook",
        author: "Test Author",
        book_type: :audiobook,
        file_path: library_path
      )

      delete library_path(book), params: { delete_files: "1" }

      assert_redirected_to library_index_path
      assert_not File.exist?(library_path)
      assert_not Book.exists?(book.id)
    end
  end

  test "destroy never follows a symlinked library ancestor" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-library-root") do |root|
      Dir.mktmpdir("shelfarr-library-outside") do |outside|
        victim = File.join(outside, "victim.epub")
        File.binwrite(victim, "keep me")
        File.symlink(outside, File.join(root, "swapped"))
        SettingsService.set(:ebook_output_path, root)
        book = Book.create!(
          title: "Symlink Escape",
          author: "Test Author",
          book_type: :ebook,
          file_path: File.join(root, "swapped", "victim.epub")
        )

        delete library_path(book), params: { delete_files: "1" }

        assert_redirected_to library_path(book)
        assert_equal "keep me", File.binread(victim)
        assert Book.exists?(book.id)
        assert_match(/record was kept/, flash[:alert])
      end
    end
  end

  test "destroy uses recorded Audible provenance after the output setting changes" do
    sign_out
    sign_in_as(@admin)
    Dir.mktmpdir("shelfarr-old-audiobooks") do |old_root|
      Dir.mktmpdir("shelfarr-new-audiobooks") do |new_root|
        library_path = File.join(old_root, "Audible Author", "Audible Title")
        destination = File.join(library_path, "Audible Title.m4b")
        staging_path = File.join(
          old_root,
          OwnedMediaImportFileService::STAGING_DIRECTORY,
          OwnedMediaImportFileService::UPLOADS_DIRECTORY,
          "recorded",
          "libation.m4b"
        )
        FileUtils.mkdir_p(File.dirname(staging_path))
        FileUtils.mkdir_p(library_path)
        File.binwrite(destination, "owned audio")
        book = Book.create!(
          title: "Audible Title",
          author: "Audible Author",
          book_type: :audiobook,
          file_path: library_path
        )
        connection = create_audible_connection
        item = connection.owned_library_items.create!(
          external_id: "B012345678",
          title: book.title,
          ownership_type: "purchased",
          book: book
        )
        upload = Upload.create!(
          user: @admin,
          book: book,
          original_filename: "Audible Title.m4b",
          file_path: staging_path,
          file_size: File.size(destination),
          status: :completed
        )
        item.owned_media_imports.create!(
          upload: upload,
          status: "completed",
          destination_path: destination,
          library_path: library_path,
          completed_at: Time.current
        )
        SettingsService.set(:audiobook_output_path, new_root)

        delete library_path(book), params: { delete_files: "1" }

        assert_redirected_to library_index_path
        assert_not File.exist?(library_path)
        assert_not Book.exists?(book.id)
      end
    end
  end

  private

  def catalog_card_keys
    css_select("#library-catalog [data-library-card]").map do |node|
      record_id = node["data-library-book-id"] || node["data-owned-library-item-id"]
      "#{node['data-library-source']}:#{record_id}"
    end
  end

  def create_audible_connection
    OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "token",
      enabled: true
    )
  end
end
