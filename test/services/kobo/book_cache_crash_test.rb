# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_household_test_helper"

# Workers here really die: a forked process runs the production reservation,
# download and promotion path and is killed with SIGKILL, so no Ruby ensure
# block can clean up. Only synthetic EPUBs and stubbed Kobo hosts are used.
class Kobo::BookCacheCrashTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include KoboHouseholdTestHelper
  # The killed worker must see committed rows through its own SQLite connection.
  self.use_transactional_tests = false

  setup { setup_kobo_household }
  teardown do
    [ KoboDelivery, KoboLocalEntitlement, KoboDevice, KoboAccountBookFile, KoboAccountShare, KoboAccountBook, KoboAccount ]
      .each(&:delete_all)
    teardown_kobo_household
  end

  test "a killed worker's partial is reclaimed, not double counted, when the title is retried" do
    stub_book_metadata
    stub_book_download
    first = Kobo::BookCache.request!(@shared_book, @owner)
    kill_during_transfer(first)
    assert_equal synthetic_epub.bytesize, incoming_bytes(".part")

    cap = (synthetic_epub.bytesize * 1.5).to_i
    travel(KoboAccountBookFile::FETCH_LEASE + 1.minute) do
      with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => cap.to_s) do
        second = Kobo::BookCache.request!(@shared_book, @owner)
        assert_not_equal first.id, second.id
        assert_equal [ "failed", "timed_out" ], [ first.reload.status, first.error ]
        Kobo::BookCache.new(second).call
        assert_equal "ready", second.reload.status, second.error
        assert_not KoboAccountBookFile.exists?(first.id)
        assert_operator physical_bytes, :<=, cap
        assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
        assert_equal synthetic_epub, Kobo::BookCache.open(second).read
      end
    end
  end

  test "another title reclaims a dead worker at once while two live titles share the bound" do
    second_title = add_title("22222222-2222-3333-4444-555555555555", "Second")
    third_title = add_title("33333333-2222-3333-4444-555555555555", "Third")
    [ @shared_book, second_title, third_title ].each { |book| stub_book_metadata(book) }
    stub_book_download
    dead = Kobo::BookCache.request!(@shared_book, @owner)
    kill_during_transfer(dead)
    second = Kobo::BookCache.request!(second_title, @owner)
    third = Kobo::BookCache.request!(third_title, @owner)
    downloader = Kobo::BookDownload.new
    overlap = Object.new
    overlap.define_singleton_method(:call) do |url, **options|
      downloader.call(url, **options).tap { Kobo::BookCache.new(third).call }
    end
    cap = (synthetic_epub.bytesize * 2.5).to_i
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => cap.to_s) do
      Kobo::BookCache.new(second, downloader: overlap).call
      assert_equal "ready", third.reload.status, third.error
      assert_equal "ready", second.reload.status, second.error
      assert_operator physical_bytes, :<=, cap
      assert_equal [ "failed", "incomplete" ], [ dead.reload.status, dead.error ]
      assert_empty Dir.children(File.join(@kobo_cache, ".incoming"))
    end
  end

  test "a worker killed between renaming its replacement and recording it keeps the earlier edition" do
    previous = prepare_copy
    path = File.join(@kobo_cache, previous.storage_key)
    edition = synthetic_epub(version: "2.0")
    @shared_book.update!(revision_id: "edition-2", download_size: edition.bytesize)
    stub_book_metadata(revision: "edition-2", entries: download_entries(size: edition.bytesize))
    stub_book_download(edition)
    replacement = Kobo::BookCache.request!(@shared_book, @owner)
    kill_after_rename(replacement)
    orphan = File.join(@kobo_cache, "#{@account.id}/#{@shared_book.id}/#{Digest::SHA256.hexdigest(edition)}.epub")
    assert File.exist?(orphan)
    assert_equal "fetching", replacement.reload.status

    other = add_title("22222222-2222-3333-4444-555555555555", "Second")
    cap = synthetic_epub.bytesize + edition.bytesize + (synthetic_epub.bytesize / 2)
    with_env("KOBO_ACCOUNT_CACHE_MAX_BYTES" => cap.to_s) do
      stub_book_metadata(other)
      stub_book_download
      row = Kobo::BookCache.request!(other, @owner)
      Kobo::BookCache.new(row).call
      assert_equal "ready", row.reload.status, row.error
      assert_not File.exist?(orphan)
      assert_equal [ "failed", "incomplete" ], [ replacement.reload.status, replacement.error ]
      assert previous.reload.ready?
      assert_equal previous, @shared_book.ready_file
      assert_equal synthetic_epub, File.binread(path)
      assert_operator physical_bytes, :<=, cap
    end
  end

  private

  def add_title(entitlement, title)
    @account.kobo_account_books.create!(entitlement_id: entitlement, title: title, ownership_type: "purchased",
      rights: "drm_free", download_size: synthetic_epub.bytesize, rights_checked_at: Time.current)
  end

  # Writes and syncs every byte, then the worker dies before validating them.
  def kill_during_transfer(row)
    bytes = synthetic_epub
    writer = Object.new
    writer.define_singleton_method(:call) do |_url, io:, expected_size:|
      raise "unexpected reservation" unless expected_size == bytes.bytesize

      io.write(bytes)
      io.flush
      io.fsync
      Process.kill("KILL", Process.pid)
    end
    run_and_kill(row, downloader: writer)
  end

  # The worker dies right after renaming its file into place, before its row
  # records the copy.
  def kill_after_rename(row)
    run_and_kill(row) do
      File.singleton_class.prepend(Module.new do
        def rename(from, to)
          super.tap { Process.kill("KILL", Process.pid) if to.to_s.end_with?(".epub") }
        end
      end)
    end
  end

  def run_and_kill(row, downloader: Kobo::BookDownload.new)
    pid = fork do
      ActiveRecord::Base.connection_pool.disconnect!
      yield if block_given?
      Kobo::BookCache.new(KoboAccountBookFile.find(row.id), downloader: downloader).call
      exit!(7)
    end
    _, status = Process.wait2(pid)
    assert status.signaled?, "the worker was expected to die, not exit #{status.exitstatus.inspect}"
    assert_equal Signal.list.fetch("KILL"), status.termsig
  end

  def incoming_bytes(suffix)
    Dir.glob(File.join(@kobo_cache, ".incoming", "*#{suffix}")).sum { |path| File.size(path) }
  end

  def physical_bytes
    Dir.glob(File.join(@kobo_cache, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sum { |path| File.size(path) }
  end
end
