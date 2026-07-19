# frozen_string_literal: true

require "test_helper"

class OwnedLibraryBacklogBackupTest < ActiveJob::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(
      enabled: true,
      last_synced_at: Time.current
    )
    @admin = users(:two)
  end

  test "preview includes downloaded artifacts but only safe purchased audiobooks without prior imports" do
    eligible = create_item(external_id: "B000000001", title: "Eligible")
    downloaded = create_item(
      external_id: "B000000002",
      title: "Already liberated",
      downloaded: true,
      backed_up_at: 1.day.ago,
      file_path: "/data/already-liberated/book.m4b"
    )
    create_item(external_id: "B000000003", title: "Subscription", ownership_type: "subscription")
    create_item(external_id: "B000000004", title: "Inactive", active: false)
    create_item(external_id: "B000000005", title: "Ebook", media_type: "ebook")
    acquired = create_item(external_id: "B000000006", title: "Acquired")
    acquired.update!(book: books(:audiobook_acquired))
    prior = create_item(external_id: "B000000007", title: "Prior failure")
    prior.owned_media_imports.create!(status: "failed")

    preview = OwnedLibraryBacklogBackup.preview(connection: @connection)

    assert_equal 2, preview.eligible_count
    assert_equal [ downloaded.id, eligible.id ].sort,
      safe_eligible_item_ids
  end

  test "preview excludes stable local matches and ambiguous editions" do
    stable_book = Book.create!(
      title: "Stable local copy",
      isbn: "9781234567897",
      book_type: :audiobook,
      file_path: "/audiobooks/stable"
    )
    LibraryItem.create!(
      library_platform: SettingsService.active_library_platform,
      library_id: "library-backlog",
      audiobookshelf_id: "stable-backlog",
      asin: "B000000011",
      isbn: stable_book.isbn
    )
    create_item(external_id: "B000000011", title: "Different provider title")

    Book.create!(
      title: "Shared edition",
      author: "A Writer",
      narrator: "A Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/shared-edition"
    )
    create_item(
      external_id: "B000000012",
      title: "Shared edition",
      authors: [ "A Writer" ],
      narrators: [ "A Narrator" ]
    )

    assert_equal 0, OwnedLibraryBacklogBackup.preview(connection: @connection).eligible_count
  end

  test "preview rejects a prior import before running local-library matching" do
    item = create_item(external_id: "B000000013", title: "Already attempted")
    item.owned_media_imports.create!(status: "failed")
    matcher = Object.new
    matcher.define_singleton_method(:resolve) do |*|
      raise "prior imports must short-circuit matching"
    end

    OwnedLibraryBookMatcher.stub(:new, matcher) do
      assert_equal 0,
        OwnedLibraryBacklogBackup.preview(connection: @connection).eligible_count
    end
  end

  test "call requires explicit confirmation and an active administrator" do
    create_item(external_id: "B000000021", title: "Eligible")

    assert_raises(OwnedLibraryBacklogBackup::ConfirmationRequired) do
      OwnedLibraryBacklogBackup.call(
        connection: @connection,
        requested_by: @admin,
        confirmed: false
      )
    end
    assert_raises(OwnedLibraryBacklogBackup::InvalidRequester) do
      OwnedLibraryBacklogBackup.call(
        connection: @connection,
        requested_by: users(:one),
        confirmed: true
      )
    end

    assert_not @connection.reload.backlog_backup_decided?
    assert_equal 0, OwnedMediaImport.count
  end

  test "call requires a completed library sync before recording a decision" do
    create_item(external_id: "B000000022", title: "Not synced")
    @connection.update!(last_synced_at: nil)

    error = assert_raises(OwnedLibraryBacklogBackup::ConnectionUnavailable) do
      OwnedLibraryBacklogBackup.call(
        connection: @connection,
        requested_by: @admin,
        confirmed: true
      )
    end

    assert_match(/sync the Audible library/i, error.message)
    assert_not @connection.reload.backlog_backup_decided?
    assert_equal 0, OwnedMediaImport.count
  end

  test "confirmation records the decision and creates passive visible backlog work" do
    first = create_item(external_id: "B000000031", title: "First")
    second = create_item(external_id: "B000000032", title: "Second", downloaded: true)
    result = nil

    assert_enqueued_with(job: OwnedLibraryAutomationJob) do
      result = OwnedLibraryBacklogBackup.call(
        connection: @connection,
        requested_by: @admin,
        confirmed: true
      )
    end

    assert_equal :queued, result.status
    assert result.queued?
    assert_equal 2, result.eligible_count
    assert_equal 2, result.queued_count
    assert @connection.reload.backlog_backup_decided?
    imports = OwnedMediaImport.order(:owned_library_item_id)
    assert_equal [ first.id, second.id ], imports.pluck(:owned_library_item_id)
    assert imports.all?(&:pending?)
    assert imports.all?(&:automatic?)
    assert imports.all? { |media_import| media_import.requested_by == @admin }
    assert_not OwnedMediaImport.active.exists?
  end

  test "confirmation scales to a large logical backlog without creating active imports or backup jobs" do
    125.times do |index|
      create_item(
        external_id: format("B%09d", index + 100),
        title: "Backlog title #{index}"
      )
    end

    result = nil
    insert_sizes = []
    original_insert = OwnedMediaImport.method(:insert_all!)
    batched_insert = lambda do |rows, **options|
      insert_sizes << rows.size
      original_insert.call(rows, **options)
    end
    OwnedMediaImport.stub(:insert_all!, batched_insert) do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        result = OwnedLibraryBacklogBackup.call(
          connection: @connection,
          requested_by: @admin,
          confirmed: true
        )
      end
    end

    assert_equal 125, result.queued_count
    assert_equal [ 100, 25 ], insert_sizes
    assert_equal 125, OwnedMediaImport.pending.count
    assert_equal 0, OwnedMediaImport.active.count
  end

  test "SQL prefilter prevents prior attempts from reaching the local matcher" do
    now = Time.current
    item_rows = 400.times.map do |index|
      {
        owned_library_connection_id: @connection.id,
        external_id: format("P%09d", index),
        title: "Previously attempted #{index}",
        authors: [],
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
    OwnedLibraryItem.insert_all!(item_rows)
    blocked_ids = @connection.owned_library_items.where("external_id LIKE 'P%'").pluck(:id)
    OwnedMediaImport.insert_all!(blocked_ids.map do |item_id|
      {
        owned_library_item_id: item_id,
        status: "failed",
        automatic: false,
        separate_edition: false,
        companion_start_attempts: 0,
        upload_recovery_attempts: 0,
        created_at: now,
        updated_at: now
      }
    end)
    create_item(external_id: "B000000099", title: "Only eligible candidate")
    resolution = OwnedLibraryBookMatcher::Resolution.new(book: nil, status: :none, source: nil)
    resolve_calls = 0
    matcher = Object.new
    matcher.define_singleton_method(:resolve) do |_item|
      resolve_calls += 1
      resolution
    end

    preview = nil
    OwnedLibraryBookMatcher.stub(:new, matcher) do
      preview = OwnedLibraryBacklogBackup.preview(connection: @connection)
    end

    assert_equal 1, preview.eligible_count
    assert_equal 1, resolve_calls
  end

  test "potential candidate check is bounded and does not claim exact eligibility" do
    create_item(external_id: "B000000098", title: "Potential candidate")

    OwnedLibraryBookMatcher.stub(:new, ->(*) { flunk "potential check must remain SQL-only" }) do
      assert OwnedLibraryBacklogBackup.potential_candidates?(connection: @connection)
    end
  end

  test "calling again is idempotent and never duplicates prior backlog records" do
    create_item(external_id: "B000000041", title: "One time")

    first = OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )
    second = OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )

    assert_equal 1, first.queued_count
    assert_equal :nothing_to_queue, second.status
    assert_equal 0, second.eligible_count
    assert_equal 0, second.queued_count
    assert_equal 1, OwnedMediaImport.count
  end

  test "dispatcher activates only one pending title and leaves the rest passive" do
    create_item(external_id: "B000000051", title: "First")
    create_item(external_id: "B000000052", title: "Second")
    OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )
    clear_enqueued_jobs
    result = nil

    assert_enqueued_with(job: OwnedMediaBackupJob) do
      result = OwnedLibraryBacklogBackup.dispatch_next(connection: @connection)
    end

    assert_equal :dispatched, result.status
    assert result.media_import.queued?
    assert result.media_import.dispatched_at.present?
    assert result.media_import.poll_token.present?
    assert_equal 1, OwnedMediaImport.active.count
    assert_equal 1, OwnedMediaImport.pending.count

    blocked = OwnedLibraryBacklogBackup.dispatch_next(connection: @connection)
    assert_equal :backup_active, blocked.status
    assert_equal 1, OwnedMediaImport.active.count
  end

  test "dispatcher revalidates pending titles and skips an item that became ineligible" do
    invalid = create_item(external_id: "B000000061", title: "No longer purchased")
    create_item(external_id: "B000000062", title: "Still eligible")
    OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )
    clear_enqueued_jobs
    invalid.update!(ownership_type: "subscription")

    result = OwnedLibraryBacklogBackup.dispatch_next(connection: @connection)

    assert_equal :dispatched, result.status
    assert invalid.owned_media_imports.first.reload.cancelled?
    assert_match(/no longer an active purchased audiobook/i,
      invalid.owned_media_imports.first.error_message)
    assert_equal "Still eligible", result.media_import.owned_library_item.title
  end

  test "dispatcher yields to authentication due syncs and manual backup work" do
    item = create_item(external_id: "B000000071", title: "Waiting")
    OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )
    clear_enqueued_jobs

    @connection.update!(
      auth_session_id: "session-1",
      auth_login_url: "https://www.amazon.com/ap/signin?example=1",
      auth_expires_at: 10.minutes.from_now
    )
    assert_equal :auth_active,
      OwnedLibraryBacklogBackup.dispatch_next(connection: @connection).status

    @connection.clear_auth_state!
    @connection.update!(scheduled_sync_enabled: true)
    @connection.update_column(:next_scheduled_sync_at, 1.minute.ago)
    assert_equal :sync_due,
      OwnedLibraryBacklogBackup.dispatch_next(connection: @connection).status

    @connection.update_column(:next_scheduled_sync_at, 1.hour.from_now)
    manual_item = create_item(external_id: "B000000072", title: "Manual")
    manual_item.owned_media_imports.create!(status: "queued", requested_by: @admin)
    assert_equal :backup_active,
      OwnedLibraryBacklogBackup.dispatch_next(connection: @connection).status
    assert item.owned_media_imports.first.reload.pending?
  end

  test "a backup enqueue failure releases the passive claim for durable retry" do
    create_item(external_id: "B000000081", title: "Retry later")
    OwnedLibraryBacklogBackup.call(
      connection: @connection,
      requested_by: @admin,
      confirmed: true
    )
    clear_enqueued_jobs

    result = nil
    OwnedMediaBackupJob.stub(:perform_later, false) do
      result = OwnedLibraryBacklogBackup.dispatch_next(connection: @connection)
    end

    assert_equal :enqueue_failed, result.status
    media_import = OwnedMediaImport.first.reload
    assert media_import.pending?
    assert_nil media_import.poll_token
    assert_nil media_import.dispatched_at
    assert_match(/could not queue/i, media_import.error_message)
    assert_not OwnedMediaImport.active.exists?
  end

  private

  def create_item(attributes)
    defaults = {
      ownership_type: "purchased",
      media_type: "audiobook",
      active: true
    }
    @connection.owned_library_items.create!(defaults.merge(attributes))
  end

  def safe_eligible_item_ids
    matcher = OwnedLibraryBookMatcher.new
    @connection.owned_library_items.filter_map do |item|
      next unless item.active? && item.purchased? && item.media_type == "audiobook"
      next if item.book&.acquired?
      next if item.owned_media_imports.exists?

      resolution = matcher.resolve(item)
      item.id unless resolution.matched? || resolution.conflict?
    end
  end
end
