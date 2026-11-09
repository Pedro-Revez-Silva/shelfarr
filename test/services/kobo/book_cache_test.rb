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
