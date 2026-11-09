# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_household_test_helper"

class Kobo::BookCacheTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include KoboHouseholdTestHelper

  setup { setup_kobo_household }
  teardown { teardown_kobo_household }

  test "owners and recipients queue one fetch at a time; others cannot" do
    share_with
    row = nil
    assert_enqueued_with(job: KoboBookFetchJob) { row = Kobo::BookCache.request!(@shared_book, @recipient) }
    assert_equal "fetching", row.status
    assert_equal @recipient, row.requested_by
    assert_no_enqueued_jobs(only: KoboBookFetchJob) { assert_equal row, Kobo::BookCache.request!(@shared_book, @owner) }
    stranger = User.create!(username: "stranger", name: "Stranger", password: "Password123!x")
    assert_raises(Kobo::HouseholdAccess::Denied) { Kobo::BookCache.request!(@shared_book, stranger) }
    @recipient.update!(deleted_at: Time.current)
    assert_raises(Kobo::HouseholdAccess::Denied) { Kobo::BookCache.request!(@shared_book, @recipient) }
  end

  test "ineligible titles, disconnected accounts and request floods are refused before any work" do
    @shared_book.update!(rights: "protected")
    assert_equal "not_eligible", assert_raises(Kobo::BookCache::Failure) { Kobo::BookCache.request!(@shared_book, @owner) }.code
    @shared_book.update!(rights: "drm_free", ownership_type: "subscription")
    assert_equal "not_eligible", assert_raises(Kobo::BookCache::Failure) { Kobo::BookCache.request!(@shared_book, @owner) }.code
    @shared_book.update!(ownership_type: "purchased")
    @account.update!(status: "reauthorization_required")
    assert_equal "reauthorization_required", assert_raises(Kobo::BookCache::Failure) { Kobo::BookCache.request!(@shared_book, @owner) }.code
    @account.update!(status: "connected")
    Kobo::BookCache::PER_USER_HOURLY.times do
      @shared_book.kobo_account_book_files.create!(status: "failed", error: "incomplete", request_id: SecureRandom.uuid, requested_by: @owner)
    end
    assert_equal "rate_limited", assert_raises(Kobo::BookCache::Failure) { Kobo::BookCache.request!(@shared_book, @owner) }.code
  end

  test "a complete DRM-free EPUB is validated, stored privately and pinned to its inode" do
    row = prepare_copy
    assert_equal "ready", row.status, row.error
    digest = Digest::SHA256.hexdigest(synthetic_epub)
    assert_equal "#{@account.id}/#{@shared_book.id}/#{digest}.epub", row.storage_key
    assert_equal [ synthetic_epub.bytesize, "EPUB3", "edition-1", "3.0" ], [ row.size_bytes, row.format, row.kobo_revision_id, row.epub_version ]
    path = File.join(@kobo_cache, row.storage_key)
    assert_equal synthetic_epub, File.binread(path)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    [ File.dirname(path), File.dirname(path, 2), @kobo_cache ].each do |directory|
      assert_equal "700", format("%o", File.stat(directory).mode & 0o777), directory
    end
    assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
    Kobo::BookCache.open(row).tap { |file| assert_equal synthetic_epub, file.read }.close
    assert_not_requested(:get, KoboHouseholdTestHelper::FILE_URL, headers: { "Authorization" => /./ })
    assert_no_difference("Book.count") { prepare_copy }
  end

  test "failed, truncated, protected or invalid downloads keep the previous ready copy" do
    ready = prepare_copy
    {
      synthetic_epub.byteslice(0, 100) => "incomplete",
      synthetic_epub(extra: { "META-INF/encryption.xml" => "<encryption/>" }) => "protected_file",
      "PK not really a zip file" => "invalid_file"
    }.each do |bytes, code|
      @shared_book.update!(download_size: bytes.bytesize) unless code == "incomplete"
      stub_book_metadata(entries: download_entries(size: code == "incomplete" ? synthetic_epub.bytesize : bytes.bytesize))
      stub_book_download(bytes, length: bytes.bytesize)
      row = Kobo::BookCache.request!(@shared_book, @owner)
      Kobo::BookCache.new(row).call
      assert_equal [ "failed", code ], [ row.reload.status, row.error ]
      assert_nil row.storage_key
      assert_equal ready, @shared_book.ready_file
      assert File.exist?(File.join(@kobo_cache, ready.storage_key))
      assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
    end
    assert_equal 1, Dir.glob(File.join(@kobo_cache, "*/*/*.epub")).size
  end

  test "Kobo no longer offering a DRM-free file, or untrusted links, fail honestly" do
    stub_book_metadata(entries: download_entries(drm: "KDRM"))
    row = Kobo::BookCache.request!(@shared_book, @owner)
    Kobo::BookCache.new(row).call
    assert_equal "not_eligible", row.reload.error
    stub_book_metadata(entries: download_entries(url: "https://evil.example/book.epub"))
    row = Kobo::BookCache.request!(@shared_book, @owner)
    Kobo::BookCache.new(row).call
    assert_equal "not_eligible", row.reload.error
    assert_not_requested :get, /evil\.example/
  end

  test "a replacement without staging capacity preserves the earlier valid edition" do
    previous = prepare_copy
    path = File.join(@kobo_cache, previous.storage_key)
    @shared_book.update!(revision_id: "edition-2")
    stub_book_metadata(revision: "edition-2")
    stub_book_download("truncated", length: synthetic_epub.bytesize)
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 1.5).to_i.to_s) do
      row = Kobo::BookCache.request!(@shared_book, @owner)
      Kobo::BookCache.new(row).call
      assert_equal [ "failed", "cache_full" ], [ row.reload.status, row.error ]
      assert previous.reload.ready?
      assert_equal synthetic_epub, File.binread(path)
      assert_equal previous, @shared_book.ready_file
    end
  end

  test "overlapping fetches reserve capacity before either downloads" do
    other = @account.kobo_account_books.create!(entitlement_id: "22222222-2222-3333-4444-555555555555", title: "Second",
      ownership_type: "purchased", rights: "drm_free", rights_checked_at: Time.current)
    stub_book_metadata
    stub_book_metadata(other)
    stub_book_download
    first = Kobo::BookCache.request!(@shared_book, @owner)
    second = Kobo::BookCache.request!(other, @owner)
    downloader = Kobo::BookDownload.new
    overlap = Object.new
    overlap.define_singleton_method(:call) do |url, **options|
      Kobo::BookCache.new(second).call
      downloader.call(url, **options)
    end
    cap = (synthetic_epub.bytesize * 1.5).to_i
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => cap.to_s) do
      Kobo::BookCache.new(first, downloader: overlap).call
      assert first.reload.ready?
      assert_equal [ "failed", "cache_full" ], [ second.reload.status, second.error ]
      assert_operator KoboAccountBookFile.where(status: "ready").sum(:size_bytes), :<=, cap
      assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
    end
  end

  test "disconnecting while bytes arrive leaves no private EPUB without an owner" do
    stub_book_metadata
    stub_book_download
    row = Kobo::BookCache.request!(@shared_book, @owner)
    downloader = Kobo::BookDownload.new
    account = @account
    disconnect = Object.new
    disconnect.define_singleton_method(:call) do |url, **options|
      downloader.call(url, **options).tap { account.destroy! }
    end
    Kobo::BookCache.new(row, downloader: disconnect).call
    assert_equal 0, KoboAccountBookFile.count
    assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
    assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
  end

  test "another fetch cannot evict a valid edition while its replacement is in flight" do
    previous = prepare_copy
    path = File.join(@kobo_cache, previous.storage_key)
    other = @account.kobo_account_books.create!(entitlement_id: "22222222-2222-3333-4444-555555555555", title: "Second",
      ownership_type: "purchased", rights: "drm_free", rights_checked_at: Time.current)
    stub_book_metadata
    stub_book_metadata(other)
    stub_book_download("truncated", length: synthetic_epub.bytesize)
    first = Kobo::BookCache.request!(@shared_book, @owner)
    second = Kobo::BookCache.request!(other, @owner)
    downloader = Kobo::BookDownload.new
    overlap = Object.new
    overlap.define_singleton_method(:call) do |url, **options|
      Kobo::BookCache.new(second).call
      downloader.call(url, **options)
    end
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 2.5).to_i.to_s) do
      Kobo::BookCache.new(first, downloader: overlap).call
      assert_equal [ "failed", "incomplete" ], [ first.reload.status, first.error ]
      assert_equal [ "failed", "cache_full" ], [ second.reload.status, second.error ]
      assert previous.reload.ready?
      assert_equal synthetic_epub, File.binread(path)
    end
  end

  test "a live worker keeps its partial and its reservation however old its lease grows" do
    stub_book_metadata
    stub_book_download
    first = Kobo::BookCache.request!(@shared_book, @owner)
    test = self
    seen = {}
    downloader = Kobo::BookDownload.new
    slow = Object.new
    slow.define_singleton_method(:call) do |url, **options|
      downloader.call(url, **options).tap do
        cache = test.instance_variable_get(:@kobo_cache)
        seen[:leases] = Dir.glob(File.join(cache, ".incoming", "*.lease")).map { |path| File.read(path) }
        test.travel(KoboAccountBookFile::FETCH_LEASE * 2 + 1.minute)
        seen[:retry] = Kobo::BookCache.request!(test.instance_variable_get(:@shared_book), test.users(:one))
        Kobo::BookCache.new(seen[:retry]).call
        seen[:partial] = File.size(options[:io].tap(&:flush).path) if File.exist?(options[:io].path)
      end
    end
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 1.5).to_i.to_s) do
      Kobo::BookCache.new(first, downloader: slow).call
      assert_equal [ "failed", "cache_full" ], [ seen[:retry].reload.status, seen[:retry].error ]
      assert_equal synthetic_epub.bytesize, seen[:partial]
      # Its row was superseded meanwhile, so the late result is discarded.
      assert_equal [ "failed", "timed_out" ], [ first.reload.status, first.error ]
      assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
      assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
      row = Kobo::BookCache.request!(@shared_book, @owner)
      Kobo::BookCache.new(row).call
      assert_equal "ready", row.reload.status, row.error
    end
    # The reservation records only ids, a random request id and a byte count.
    assert_equal [ %w[bytes request row] ], seen[:leases].map { |text| JSON.parse(text).keys.sort }
    assert_no_match(/signature|token|kobo\.com/, seen[:leases].join)
  end

  test "a disconnected account's transfer keeps its reservation until its bytes are gone" do
    other_account = connect_kobo_account(user: @recipient, name: "Second household account")
    other = other_account.kobo_account_books.create!(entitlement_id: "22222222-2222-3333-4444-555555555555",
      title: "Second", ownership_type: "purchased", rights: "drm_free", rights_checked_at: Time.current)
    stub_book_metadata
    stub_book_metadata(other)
    stub_book_download
    row = Kobo::BookCache.request!(@shared_book, @owner)
    blocked = Kobo::BookCache.request!(other, @recipient)
    downloader = Kobo::BookDownload.new
    account = @account
    disconnect = Object.new
    disconnect.define_singleton_method(:call) do |url, **options|
      downloader.call(url, **options).tap do
        account.destroy!
        Kobo::BookCache.new(blocked).call
      end
    end
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 1.5).to_i.to_s) do
      Kobo::BookCache.new(row, downloader: disconnect).call
      assert_equal [ "failed", "cache_full" ], [ blocked.reload.status, blocked.error ]
      assert_not KoboAccountBookFile.exists?(row.id)
      assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
      assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
      retried = Kobo::BookCache.request!(other, @recipient)
      Kobo::BookCache.new(retried).call
      assert_equal "ready", retried.reload.status, retried.error
    end
  end

  test "reservations nobody holds and unreferenced files are reclaimed; held ones still count" do
    kept = prepare_copy
    device, = recipient_device(@owner)
    device.send_account_book!(kept, share: nil)
    incoming = File.join(@kobo_cache, ".incoming")
    abandoned = @shared_book.kobo_account_book_files.create!(status: "fetching", request_id: SecureRandom.uuid,
      requested_by: @owner, started_at: Time.current)
    dead = SecureRandom.hex(16)
    File.write(File.join(incoming, "#{dead}.lease"), { row: abandoned.id, request: abandoned.request_id, bytes: 900 }.to_json)
    File.write(File.join(incoming, "#{dead}.part"), "x" * 900)
    File.write(File.join(incoming, "#{SecureRandom.hex(16)}.part"), "legacy partial")
    orphan = File.join(@kobo_cache, @account.id.to_s, "999", "#{'b' * 64}.epub")
    FileUtils.mkdir_p(File.dirname(orphan))
    File.write(orphan, "renamed but never recorded")
    live = SecureRandom.hex(16)
    File.write(File.join(incoming, "#{live}.part"), "y" * 400)
    holder = File.open(File.join(incoming, "#{live}.lease"), "w+")
    holder.write({ row: 0, request: "live", bytes: 100 }.to_json)
    holder.flush
    assert holder.flock(File::LOCK_EX | File::LOCK_NB)

    other = @account.kobo_account_books.create!(entitlement_id: "22222222-2222-3333-4444-555555555555", title: "Second",
      ownership_type: "purchased", rights: "drm_free", rights_checked_at: Time.current)
    # The pinned copy plus the live partial (larger than its reservation) leave no room.
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 2 + 399).to_s) do
      row = prepare_copy(other)
      assert_equal [ "failed", "cache_full" ], [ row.status, row.error ]
      assert_equal [ "failed", "incomplete" ], [ abandoned.reload.status, abandoned.error ]
      assert_equal [ "#{live}.lease", "#{live}.part" ], Dir.children(incoming).sort
      assert_not File.exist?(orphan)
      assert_equal synthetic_epub, File.binread(File.join(@kobo_cache, kept.storage_key))

      holder.close
      row = prepare_copy(other)
      assert_equal "ready", row.status, row.error
      assert_empty Dir.children(incoming)
      assert kept.reload.ready?
    end
  ensure
    holder&.close
  end

  test "a revoked share during the transfer leaves nothing saved" do
    share = share_with
    stub_book_metadata
    stub_book_download
    row = Kobo::BookCache.request!(@shared_book, @recipient)
    downloader = Kobo::BookDownload.new
    revoking = Object.new
    revoking.define_singleton_method(:call) do |url, **options|
      downloader.call(url, **options).tap { share.destroy! }
    end
    Kobo::BookCache.new(row, downloader: revoking).call
    assert_equal [ "failed", "access_revoked" ], [ row.reload.status, row.error ]
    assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
  end

  test "a superseded or late result does not override a newer attempt" do
    row = Kobo::BookCache.request!(@shared_book, @owner)
    travel(KoboAccountBookFile::FETCH_LEASE + 1.minute) do
      newer = Kobo::BookCache.request!(@shared_book, @owner)
      assert_not_equal row, newer
      assert_equal [ "failed", "timed_out" ], [ row.reload.status, row.error ]
      stub_book_metadata
      stub_book_download
      Kobo::BookCache.new(row).call
      assert_equal "failed", row.reload.status
      assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
      assert_empty Dir.glob(File.join(@kobo_cache, ".incoming", "*"))
    end
  end

  test "the metadata endpoint falling back to the bounded library scan" do
    stub_request(:get, "#{STORE}/v1/library/#{@shared_book.entitlement_id}/metadata").to_return(status: 400)
    item = { "NewEntitlement" => { "BookEntitlement" => { "Id" => @shared_book.entitlement_id, "OriginCategory" => "Purchased" },
      "BookMetadata" => { "RevisionId" => "edition-2", "Title" => "A Shared Purchase", "DownloadUrls" => download_entries } } }
    stub_kobo_catalogue(items: [ kobo_book, item ])
    stub_book_download
    row = Kobo::BookCache.request!(@shared_book, @owner)
    Kobo::BookCache.new(row).call
    assert_equal [ "ready", "edition-2" ], [ row.reload.status, row.kobo_revision_id ]
    assert row.stale?
  end

  test "expired credentials refresh once, and refused credentials mark the account" do
    stub_request(:get, "#{STORE}/v1/library/#{@shared_book.entitlement_id}/metadata").to_return(status: 401)
    stub_request(:post, STORE + "/v1/auth/refresh").to_return(status: 401)
    row = Kobo::BookCache.request!(@shared_book, @owner)
    Kobo::BookCache.new(row).call
    assert_equal "reauthorization_required", row.reload.error
    assert_equal "reauthorization_required", @account.reload.status
  end

  test "the bounded cache evicts unpinned copies first and refuses when only pinned copies remain" do
    first = prepare_copy
    device, = recipient_device(@owner)
    device.send_account_book!(first, share: nil)
    other = @account.kobo_account_books.create!(entitlement_id: "22222222-2222-3333-4444-555555555555", title: "Second",
      ownership_type: "purchased", rights: "drm_free", rights_checked_at: Time.current)
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => (synthetic_epub.bytesize * 1.5).to_i.to_s) do
      row = prepare_copy(other)
      assert_equal [ "failed", "cache_full" ], [ row.status, row.error ]
      assert first.reload.ready?
      device.kobo_deliveries.destroy_all
      row = prepare_copy(other)
      assert_equal "ready", row.status
      assert_not KoboAccountBookFile.exists?(first.id)
      assert_not File.exist?(File.join(@kobo_cache, first.storage_key))
    end
  end

  test "opening refuses replaced files, traversal keys and symlinks" do
    row = prepare_copy
    path = File.join(@kobo_cache, row.storage_key)
    File.binwrite("#{path}.new", synthetic_epub)
    File.rename("#{path}.new", path)
    assert_raises(KoboPublication::Unavailable) { Kobo::BookCache.open(row) }
    row.update_columns(storage_key: "../../etc/passwd")
    assert_raises(KoboPublication::Unavailable) { Kobo::BookCache.open(row) }
    assert_not row.valid?
    row = prepare_copy(bytes: synthetic_epub(version: "2.0"))
    target = File.join(@kobo_cache, row.storage_key)
    File.unlink(target)
    File.symlink(path, target)
    assert_raises(KoboPublication::Unavailable) { Kobo::BookCache.open(row) }
    Kobo::BookCache.remove("../outside.epub")
    Kobo::BookCache.remove("1/2/#{'a' * 64}.epub")
  end

  test "removing the account deletes its copies, shares and recipients' deliveries" do
    share = share_with
    row = prepare_copy
    device, = recipient_device
    device.send_account_book!(row, share: share)
    @account.destroy!
    assert_equal 0, KoboDelivery.count
    assert_equal 0, KoboAccountShare.count
    assert_empty Dir.glob(File.join(@kobo_cache, "**/*.epub"))
  end
end
