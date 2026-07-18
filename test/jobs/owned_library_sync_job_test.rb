# frozen_string_literal: true

require "test_helper"

class OwnedLibrarySyncJobTest < ActiveJob::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "token",
      enabled: true
    )
    clear_enqueued_jobs
  end

  test "starts an asynchronous companion sync and schedules a poll" do
    @connection.update!(sync_status: "queued", sync_started_at: Time.current)
    token = sync_request_token

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 202, body: { jobId: "sync-1", status: "queued" }.to_json)

      assert_enqueued_with(job: OwnedLibrarySyncJob, args: sync_poll_args(token, "sync-1")) do
        OwnedLibrarySyncJob.perform_now(@connection.id, token)
      end
    end

    @connection.reload
    assert @connection.syncing?
    assert_equal "sync-1", @connection.sync_job_id
    assert @connection.sync_started_at.present?
    scheduled_poll = enqueued_jobs.find { |payload| payload[:job] == OwnedLibrarySyncJob }
    assert_equal scheduled_poll.fetch("job_id"), @connection.sync_delivery_job_id
  end

  test "starts a legacy one-argument queued delivery" do
    @connection.update!(sync_status: "queued", sync_started_at: Time.current)

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 202, body: { jobId: "sync-legacy-start", status: "queued" }.to_json)

      OwnedLibrarySyncJob.perform_now(@connection.id)
    end

    @connection.reload
    assert @connection.syncing?
    assert_equal "sync-legacy-start", @connection.sync_job_id
    assert @connection.sync_poll_token.present?
  end

  test "recovers a missing companion job id after the startup grace period" do
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: nil,
      sync_started_at: 2.minutes.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 202, body: { jobId: "sync-recovered", status: "queued" }.to_json)

      assert_enqueued_with(job: OwnedLibrarySyncJob, args: sync_poll_args(token, "sync-recovered")) do
        OwnedLibrarySyncJob.perform_now(@connection.id, token)
      end
    end

    @connection.reload
    assert @connection.syncing?
    assert_equal "sync-recovered", @connection.sync_job_id
    assert @connection.sync_started_at < 1.minute.ago
  end

  test "waits through the startup grace period before recovering" do
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: nil,
      sync_started_at: 10.seconds.ago
    )
    token = sync_request_token

    VCR.turned_off do
      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        OwnedLibrarySyncJob.perform_now(@connection.id, token)
      end
      assert_not_requested :post, "https://libation.test/v1/sync"
    end

    assert_nil @connection.reload.sync_job_id
  end

  test "marks the sync failed when the next delayed check cannot be queued" do
    @connection.update!(sync_status: "queued", sync_started_at: Time.current)
    token = sync_request_token
    failed_enqueue = Struct.new(:successfully_enqueued?).new(false)
    scheduler = Object.new
    scheduler.define_singleton_method(:perform_later) { |*| failed_enqueue }

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 202, body: { jobId: "sync-1", status: "queued" }.to_json)

      OwnedLibrarySyncJob.stub(:set, scheduler) do
        assert_raises(OwnedLibrarySyncJob::CompanionJobFailed) do
          OwnedLibrarySyncJob.perform_now(@connection.id, token)
        end
      end
    end

    @connection.reload
    assert @connection.failed?
    assert_nil @connection.sync_job_id
    assert_match(/could not queue/, @connection.last_sync_error)
  end

  test "starts a durably queued sync and preserves the request time" do
    requested_at = 20.seconds.ago
    @connection.update!(sync_status: "queued", sync_started_at: requested_at)
    token = sync_request_token

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 202, body: { jobId: "sync-queued", status: "queued" }.to_json)

      OwnedLibrarySyncJob.perform_now(@connection.id, token)
    end

    @connection.reload
    assert @connection.syncing?
    assert_equal "sync-queued", @connection.sync_job_id
    assert_in_delta requested_at, @connection.sync_started_at, 1.second
  end

  test "a pending poll advances its heartbeat and invalidates duplicate poll jobs" do
    old_poll_token = "old-poll-chain"
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: @connection.sync_job_state_value(
        job_id: "sync-1",
        poll_token: old_poll_token
      ),
      sync_started_at: 10.minutes.ago
    )
    @connection.update_column(:updated_at, 2.minutes.ago)
    request_token = sync_request_token
    job_status = nil

    VCR.turned_off do
      job_status = stub_request(:get, "https://libation.test/v1/jobs/sync-1")
        .to_return(status: 200, body: { id: "sync-1", status: "running" }.to_json)

      assert_enqueued_with(job: OwnedLibrarySyncJob, args: sync_poll_args(request_token, "sync-1")) do
        OwnedLibrarySyncJob.perform_now(
          @connection.id,
          request_token,
          "sync-1",
          old_poll_token
        )
      end

      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        OwnedLibrarySyncJob.perform_now(
          @connection.id,
          request_token,
          "sync-1",
          old_poll_token
        )
      end
    end

    @connection.reload
    assert_equal "sync-1", @connection.sync_job_id
    assert_not_equal old_poll_token, @connection.sync_poll_token
    assert @connection.updated_at > 1.minute.ago
    assert_requested job_status, times: 1
  end

  test "the first legacy poll claims the tokenized chain and later legacy duplicates stop" do
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-legacy",
      sync_started_at: 10.minutes.ago
    )
    request_token = sync_request_token
    job_status = nil

    VCR.turned_off do
      job_status = stub_request(:get, "https://libation.test/v1/jobs/sync-legacy")
        .to_return(status: 200, body: { id: "sync-legacy", status: "running" }.to_json)

      OwnedLibrarySyncJob.perform_now(@connection.id, request_token, "sync-legacy")
      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        OwnedLibrarySyncJob.perform_now(@connection.id, request_token, "sync-legacy")
      end
    end

    assert @connection.reload.sync_poll_token.present?
    assert_requested job_status, times: 1
  end

  test "a stale delayed poll cannot start a new sync after completion" do
    @connection.update!(sync_status: "idle", sync_job_id: nil, sync_started_at: nil)

    VCR.turned_off do
      OwnedLibrarySyncJob.perform_now(@connection.id, "old-request", "completed-sync")
      assert_not_requested :post, "https://libation.test/v1/sync"
      assert_not_requested :get, %r{https://libation\.test/v1/jobs/}
    end

    assert_equal "idle", @connection.reload.sync_status
  end

  test "reconciles a completed library and preserves local backup state" do
    local_item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Local Title",
      downloaded: true,
      backed_up_at: 1.day.ago,
      file_path: "/audiobooks/Local Title",
      book: books(:audiobook_acquired)
    )
    missing_item = @connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "Missing Title"
    )
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-1",
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/sync-1")
        .to_return(status: 200, body: { id: "sync-1", status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: {
            items: [
              {
                asin: "B012345678",
                account: "private-reader@example.com",
                title: "Updated Local Title",
                authors: [ "An Author" ],
                bookStatus: "Liberated",
                isPurchased: true,
                isDownloaded: false
              },
              {
                asin: "B012345680",
                title: "New Title",
                isPlusCatalog: true,
                isDownloaded: false
              }
            ]
          }.to_json
        )
      stub_request(:get, "https://libation.test/version")
        .to_return(
          status: 200,
          body: { companionVersion: "0.1.0", libationVersion: "13.5.0" }.to_json
        )

      OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-1")
    end

    @connection.reload
    assert_equal "idle", @connection.sync_status
    assert_nil @connection.sync_job_id
    assert @connection.last_synced_at.present?
    assert_equal "13.5.0", @connection.provider_version

    local_item.reload
    assert_equal "Updated Local Title", local_item.title
    assert local_item.downloaded?
    assert_equal "/audiobooks/Local Title", local_item.file_path
    assert_equal books(:audiobook_acquired), local_item.book
    assert_equal({ "bookStatus" => "Liberated" }, local_item.provider_metadata)
    assert_not local_item.provider_metadata.key?("account")

    assert_not missing_item.reload.active?
    assert missing_item.absent_since.present?
    assert @connection.owned_library_items.find_by!(external_id: "B012345680").subscription?
  end

  test "persists a safe failure state for unexpected reconciliation errors" do
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-1",
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/sync-1")
        .to_return(status: 200, body: { id: "sync-1", status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: { items: [ { asin: "B012345678", title: "Valid payload" } ] }.to_json
        )

      database_failure = lambda do |*|
        raise ActiveRecord::RecordInvalid.new(OwnedLibraryItem.new)
      end
      OwnedLibraryItem.stub(:upsert_all, database_failure) do
        assert_raises(ActiveRecord::RecordInvalid) do
          OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-1")
        end
      end
    end

    @connection.reload
    assert_equal "failed", @connection.sync_status
    assert_equal "Unexpected ActiveRecord::RecordInvalid while syncing the Audible library",
      @connection.last_sync_error
    assert_nil @connection.sync_job_id
  end

  test "reconciliation SQL logs exclude personal Audible catalog fields" do
    secret_title = "Private Audible Title #{SecureRandom.hex(4)}"
    secret_author = "Private Audible Author #{SecureRandom.hex(4)}"
    secret_cover = "https://m.media-amazon.com/images/I/private-#{SecureRandom.hex(4)}.jpg"
    secret_path = "/private/audible/#{SecureRandom.hex(8)}/book.m4b"
    secret_series = "Private Series #{SecureRandom.hex(4)}"
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-private",
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    logs = VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/sync-private")
        .to_return(status: 200, body: { id: "sync-private", status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: { items: [ {
          asin: "B012345678",
          title: secret_title,
          authors: [ secret_author ],
          coverUrl: secret_cover,
          filePath: secret_path,
          series: secret_series,
          isPurchased: true
        } ] }.to_json)
      stub_request(:get, "https://libation.test/version")
        .to_return(status: 200, body: {
          companionVersion: "0.1.0",
          libationVersion: "13.5.0"
        }.to_json)

      capture_owned_job_logs do
        OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-private")
      end
    end.join("\n")

    assert @connection.owned_library_items.find_by!(external_id: "B012345678")
    [ secret_title, secret_author, secret_cover, secret_path, secret_series ].each do |secret|
      assert_not_includes logs, secret
    end
  end

  test "allows long scans but expires beyond the configured runtime" do
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-1",
      sync_started_at: 91.minutes.ago
    )
    token = sync_request_token

    with_env("SHELFARR_LIBATION_SYNC_TIMEOUT_MINUTES" => "90") do
      assert_raises(OwnedLibrarySyncJob::CompanionJobFailed) do
        OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-1")
      end
    end

    assert_equal "failed", @connection.reload.sync_status
    assert_match(/timed out/, @connection.last_sync_error)
  end

  test "a stale initial job cannot claim a newer queued sync" do
    old_token = 5.minutes.ago.utc.iso8601(6)
    @connection.update!(sync_status: "queued", sync_started_at: Time.current)

    VCR.turned_off do
      OwnedLibrarySyncJob.perform_now(@connection.id, old_token)
      assert_not_requested :post, "https://libation.test/v1/sync"
    end

    assert @connection.reload.queued?
  end

  test "an in-flight start response cannot attach to a superseding sync request" do
    @connection.update!(sync_status: "queued", sync_started_at: 5.minutes.ago)
    old_token = sync_request_token
    newer_started_at = Time.current

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return do
          @connection.reload.update!(
            sync_status: "queued",
            sync_job_id: nil,
            sync_started_at: newer_started_at
          )
          {
            status: 202,
            body: { jobId: "sync-old", status: "queued" }.to_json
          }
        end

      assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
        OwnedLibrarySyncJob.perform_now(@connection.id, old_token)
      end
    end

    @connection.reload
    assert @connection.queued?
    assert_nil @connection.sync_job_id
    assert_in_delta newer_started_at, @connection.sync_started_at, 1.second
  end

  test "a stale terminal failure cannot overwrite a newer sync request" do
    old_started_at = 5.minutes.ago
    old_token = old_started_at.utc.iso8601(6)
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-old",
      sync_started_at: old_started_at
    )
    @connection.update!(
      sync_status: "queued",
      sync_job_id: nil,
      sync_started_at: Time.current
    )

    OwnedLibrarySyncJob.new.send(
      :fail_sync,
      @connection,
      "late failure",
      sync_attempt(old_token, "sync-old", "old-chain")
    )

    assert @connection.reload.queued?
    assert_nil @connection.last_sync_error
  end

  test "a stale completed poll cannot reconcile over a newer sync request" do
    old_token = 5.minutes.ago.utc.iso8601(6)
    @connection.update!(
      sync_status: "queued",
      sync_job_id: nil,
      sync_started_at: Time.current
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: { items: [ { asin: "B012345678", title: "Stale Title" } ] }.to_json
        )

      assert_no_difference -> { OwnedLibraryItem.count } do
        OwnedLibrarySyncJob.new.send(
          :reconcile_library,
          @connection,
          sync_attempt(old_token, "sync-old", "old-chain")
        )
      end
      assert_not_requested :get, "https://libation.test/version"
    end

    assert @connection.reload.queued?
  end

  test "keeps an exact metadata match visible for a separate-edition decision" do
    Book.create!(
      title: "Local Exact Match",
      author: "Exact Author",
      narrator: "Exact Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/exact-match"
    )
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-1",
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/sync-1")
        .to_return(status: 200, body: { id: "sync-1", status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: {
            items: [
              {
                asin: "B099999999",
                title: "Local Exact Match",
                authors: [ "Exact Author" ],
                narrators: [ "Exact Narrator" ],
                isPurchased: true,
                isDownloaded: false
              }
            ]
          }.to_json
        )
      stub_request(:get, "https://libation.test/version")
        .to_return(
          status: 200,
          body: { companionVersion: "0.1.0", libationVersion: "13.5.0" }.to_json
        )

      OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-1")
    end

    item = @connection.owned_library_items.find_by!(external_id: "B099999999")
    assert_nil item.book
    assert_not item.downloaded?
    assert_nil item.backed_up_at
    assert_includes OwnedLibraryItem.visible_in_library, item
    assert OwnedLibraryBookMatcher.new.resolve(item).conflict?
  end

  test "links a local audiobook only through a stable ASIN to ISBN bridge" do
    local_book = Book.create!(
      title: "Known Local Edition",
      author: "Local Author",
      narrator: "Local Narrator",
      isbn: "9781234567897",
      book_type: :audiobook,
      file_path: "/audiobooks/known-local-edition"
    )
    LibraryItem.create!(
      library_platform: SettingsService.active_library_platform,
      library_id: "library-1",
      audiobookshelf_id: "known-item",
      asin: "B088888888",
      isbn: "978-1-2345-6789-7"
    )
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: "sync-identifier",
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/sync-identifier")
        .to_return(status: 200, body: { id: "sync-identifier", status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: {
            items: [
              {
                asin: "B088888888",
                title: "Metadata Can Differ",
                authors: [ "Different Metadata Author" ],
                narrators: [ "Different Metadata Narrator" ],
                isPurchased: true,
                isDownloaded: false
              }
            ]
          }.to_json
        )
      stub_request(:get, "https://libation.test/version")
        .to_return(
          status: 200,
          body: { companionVersion: "0.1.0", libationVersion: "13.5.0" }.to_json
        )

      OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-identifier")
    end

    item = @connection.owned_library_items.find_by!(external_id: "B088888888")
    assert_equal local_book, item.book
    assert_not item.downloaded?
    assert_nil item.backed_up_at
    assert_not_includes OwnedLibraryItem.visible_in_library, item
  end

  test "automatically queues only newly discovered and newly purchased audiobooks after the baseline" do
    enable_automatic_backups!
    transitioned = @connection.owned_library_items.create!(
      external_id: "B010000001",
      title: "Previously Unknown",
      ownership_type: "subscription"
    )
    backlog = @connection.owned_library_items.create!(
      external_id: "B010000002",
      title: "Existing Purchase",
      ownership_type: "purchased"
    )

    assert_difference -> { OwnedMediaImport.count }, 2 do
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        complete_sync([
          audible_entry(transitioned.external_id, "Now Purchased"),
          audible_entry(backlog.external_id, backlog.title),
          audible_entry("B010000003", "Brand New Purchase")
        ])
      end
    end

    imports = OwnedMediaImport.where(automatic: true).includes(:owned_library_item).to_a
    assert_equal [ "B010000001", "B010000003" ].sort,
      imports.map { |media_import| media_import.owned_library_item.external_id }.sort
    assert_equal 1, imports.count(&:queued?)
    assert_equal 1, imports.count(&:pending?)
    assert imports.all? { |media_import| media_import.requested_by == users(:two) }
    assert_equal 1, imports.count { |media_import| media_import.poll_token.present? }
    assert_equal 1, imports.count { |media_import| media_import.dispatched_at.present? }
    assert_nil backlog.owned_media_imports.first
  end

  test "automatic discoveries use bounded admission for a large purchase batch" do
    enable_automatic_backups!
    entries = 600.times.map do |index|
      audible_entry(format("B%09d", index), "New purchase #{index}")
    end

    assert_difference -> { OwnedMediaImport.count }, 600 do
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        complete_sync(entries)
      end
    end

    assert_equal 1, OwnedMediaImport.active.count
    assert_equal 599, OwnedMediaImport.pending.count
    assert_equal 1, OwnedMediaImport.where.not(dispatched_at: nil).count
    assert_equal 1, OwnedMediaImport.where.not(poll_token: nil).count
  end

  test "the first successful sync establishes a baseline without backing up the existing library" do
    enable_automatic_backups!(baseline: false)

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        complete_sync([ audible_entry("B020000001", "Existing Audible Purchase") ])
      end
    end

    assert @connection.reload.last_synced_at.present?
    assert_nil @connection.next_scheduled_sync_at
    assert @connection.owned_library_items.find_by!(external_id: "B020000001").purchased?
  end

  test "the first sync after enabling refreshes a stale baseline without backing up its discoveries" do
    @connection.update!(last_synced_at: 1.month.ago)
    enable_automatic_backups!(baseline: false, preserve_last_sync: true)

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        complete_sync([ audible_entry("B025000001", "Bought Before Opt In") ])
      end
    end

    baseline_at = @connection.reload.last_synced_at
    assert_operator baseline_at, :>=, @connection.automatic_backup_enabled_at

    assert_difference -> { OwnedMediaImport.count }, 1 do
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        complete_sync([
          audible_entry("B025000001", "Bought Before Opt In"),
          audible_entry("B025000002", "Bought After Baseline")
        ])
      end
    end
  end

  test "automatic backup skips ineligible items local matches conflicts and prior imports" do
    enable_automatic_backups!
    acquired_book = Book.create!(
      title: "Already Acquired",
      author: "Local Author",
      book_type: :audiobook,
      file_path: "/audiobooks/already-acquired"
    )
    acquired_item = @connection.owned_library_items.create!(
      external_id: "B030000001",
      title: acquired_book.title,
      ownership_type: "subscription",
      book: acquired_book
    )
    active_import_item = @connection.owned_library_items.create!(
      external_id: "B030000002",
      title: "Manual Backup Active",
      ownership_type: "subscription"
    )
    active_import_item.owned_media_imports.create!(status: "queued")
    failed_item = @connection.owned_library_items.create!(
      external_id: "B030000003",
      title: "Automatic Backup Failed",
      ownership_type: "subscription"
    )
    failed_item.owned_media_imports.create!(status: "failed", automatic: true)

    stable_book = Book.create!(
      title: "Canonical Copy",
      author: "Canonical Author",
      isbn: "9781234567897",
      book_type: :audiobook,
      file_path: "/audiobooks/canonical-copy"
    )
    LibraryItem.create!(
      library_platform: SettingsService.active_library_platform,
      library_id: "automatic-backup-library",
      audiobookshelf_id: "automatic-backup-item",
      asin: "B030000004",
      isbn: "978-1-2345-6789-7"
    )
    Book.create!(
      title: "Possible Other Edition",
      author: "Edition Author",
      narrator: "Edition Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/possible-other-edition"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        complete_sync([
          audible_entry(acquired_item.external_id, acquired_item.title),
          audible_entry(active_import_item.external_id, active_import_item.title),
          audible_entry(failed_item.external_id, failed_item.title),
          audible_entry("B030000004", "Different Provider Metadata"),
          audible_entry(
            "B030000005",
            "Possible Other Edition",
            authors: [ "Edition Author" ],
            narrators: [ "Edition Narrator" ]
          ),
          audible_entry("B030000006", "Subscription", isPurchased: false, isPlusCatalog: true),
          audible_entry("B030000007", "Inactive Purchase", active: false),
          audible_entry("B030000008", "Purchased Ebook", mediaType: "ebook")
        ])
      end
    end

    stable_item = @connection.owned_library_items.find_by!(external_id: "B030000004")
    conflict_item = @connection.owned_library_items.find_by!(external_id: "B030000005")
    assert_equal stable_book, stable_item.book
    assert OwnedLibraryBookMatcher.new.resolve(conflict_item).conflict?
  end

  test "automatic backup imports a newly discovered Libation artifact that is not yet in Shelfarr" do
    enable_automatic_backups!

    assert_difference -> { OwnedMediaImport.count }, 1 do
      assert_enqueued_jobs 1, only: OwnedMediaBackupJob do
        complete_sync([
          audible_entry("B035000001", "Already Downloaded in Libation", isDownloaded: true)
        ])
      end
    end

    item = @connection.owned_library_items.find_by!(external_id: "B035000001")
    media_import = item.owned_media_imports.find_by!(automatic: true)
    assert item.downloaded?
    assert item.backed_up_at.present?
    assert media_import.queued?
  end

  test "an automatic dispatch enqueue failure leaves durable passive work for the watchdog" do
    enable_automatic_backups!
    enqueue_calls = 0
    enqueue = lambda do |*|
      enqueue_calls += 1
      raise ActiveJob::EnqueueError, "adapter unavailable"
    end

    OwnedMediaBackupJob.stub(:perform_later, enqueue) do
      complete_sync([
        audible_entry("B040000001", "First New Purchase"),
        audible_entry("B040000002", "Second New Purchase")
      ])
    end

    assert_equal 1, enqueue_calls
    imports = OwnedMediaImport.where(automatic: true).order(:id).to_a
    assert_equal 2, imports.size
    assert imports.all?(&:pending?)
    assert_equal OwnedLibraryBacklogBackup::DISPATCH_ENQUEUE_ERROR,
      imports.first.error_message
    assert_nil imports.second.error_message
    assert imports.all? { |media_import| media_import.poll_token.nil? }
    assert imports.all? { |media_import| media_import.dispatched_at.nil? }
    assert @connection.reload.sync_status == "idle"
    assert_nil @connection.last_sync_error
  end

  test "reconciles a large unchanged library with a bounded SQL statement count" do
    now = 2.days.ago
    rows = 1_000.times.map do |index|
      {
        owned_library_connection_id: @connection.id,
        external_id: format("B%09d", index),
        title: "Existing title #{index}",
        media_type: "audiobook",
        ownership_type: "purchased",
        active: true,
        downloaded: false,
        authors: [],
        narrators: [],
        provider_metadata: {},
        created_at: now,
        updated_at: now
      }
    end
    OwnedLibraryItem.insert_all!(rows)
    entries = rows.map do |row|
      audible_entry(row.fetch(:external_id), row.fetch(:title))
    end

    sql_count = count_sql_statements { complete_sync(entries) }

    assert_operator sql_count, :<, 30,
      "expected bounded reconciliation SQL, observed #{sql_count} statements"
    assert_equal 1_000, @connection.owned_library_items.active.count
  end

  test "a repeated reconciliation does not duplicate an automatic backup intent" do
    enable_automatic_backups!
    entry = audible_entry("B050000001", "One New Purchase")

    complete_sync([ entry ])
    assert_equal 1, OwnedMediaImport.where(automatic: true).count
    clear_enqueued_jobs

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        complete_sync([ entry ])
      end
    end
  end

  test "completed and failed syncs advance the scheduled sync time" do
    travel_to Time.zone.local(2026, 7, 18, 12, 0, 0) do
      @connection.update!(
        scheduled_sync_enabled: true,
        scheduled_sync_interval_minutes: 360,
        next_scheduled_sync_at: 1.minute.ago
      )
      complete_sync([])
      assert_equal 6.hours.from_now, @connection.reload.next_scheduled_sync_at

      @connection.update!(
        sync_status: "syncing",
        sync_job_id: "sync-failed-schedule",
        sync_started_at: 1.minute.ago,
        next_scheduled_sync_at: 1.minute.ago
      )
      token = sync_request_token
      VCR.turned_off do
        stub_request(:get, "https://libation.test/v1/jobs/sync-failed-schedule")
          .to_return(
            status: 200,
            body: { id: "sync-failed-schedule", status: "failed", error: "scan failed" }.to_json
          )

        assert_raises(OwnedLibrarySyncJob::CompanionJobFailed) do
          OwnedLibrarySyncJob.perform_now(@connection.id, token, "sync-failed-schedule")
        end
      end

      assert @connection.reload.failed?
      assert_equal 6.hours.from_now, @connection.next_scheduled_sync_at
    end
  end

  private

  def enable_automatic_backups!(baseline: true, preserve_last_sync: false)
    @connection.update!(
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two)
    )
    attributes = if baseline
      {
        automatic_backup_enabled_at: 2.days.ago,
        last_synced_at: 1.day.ago
      }
    else
      { automatic_backup_enabled_at: Time.current }
    end
    attributes[:last_synced_at] = nil unless baseline || preserve_last_sync
    @connection.update!(attributes)
    clear_enqueued_jobs
  end

  def complete_sync(entries, job_id: "sync-#{SecureRandom.hex(6)}")
    @connection.update!(
      sync_status: "syncing",
      sync_job_id: job_id,
      sync_started_at: 1.minute.ago
    )
    token = sync_request_token

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/#{job_id}")
        .to_return(status: 200, body: { id: job_id, status: "completed" }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: { items: entries }.to_json)
      stub_request(:get, "https://libation.test/version")
        .to_return(
          status: 200,
          body: { companionVersion: "0.1.0", libationVersion: "13.5.0" }.to_json
        )

      OwnedLibrarySyncJob.perform_now(@connection.id, token, job_id)
    end
  end

  def audible_entry(asin, title, **overrides)
    {
      asin: asin,
      title: title,
      isPurchased: true,
      isDownloaded: false,
      active: true
    }.merge(overrides)
  end

  def sync_request_token
    @connection.reload.sync_started_at.utc.iso8601(6)
  end

  def sync_poll_args(request_token, job_id)
    lambda do |args|
      args.length == 4 &&
        args.first(3) == [ @connection.id, request_token, job_id ] &&
        args.last.present?
    end
  end

  def sync_attempt(request_token, job_id, poll_token)
    OwnedLibrarySyncJob::SyncAttempt.new(
      request_token: request_token,
      job_id: job_id,
      poll_token: poll_token
    )
  end

  def count_sql_statements
    count = 0
    callback = lambda do |*, payload|
      next if payload[:cached]
      next if payload[:name].in?(%w[SCHEMA TRANSACTION])

      count += 1
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  def capture_owned_job_logs(&job)
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
end
