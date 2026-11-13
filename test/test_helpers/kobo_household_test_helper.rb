# frozen_string_literal: true

require_relative "kobo_account_test_helper"
require_relative "kobo_test_helper"

# Synthetic household fixtures: a connected owner account with one DRM-free
# purchase, a recipient, a private cache directory and stubbed Kobo hosts.
# No real Kobo host, account, title or signed URL is used.
module KoboHouseholdTestHelper
  include KoboAccountTestHelper
  include KoboTestHelper

  DOWNLOAD_URL = "https://storedownloads.kobo.com/download?id=synthetic&signature=synthetic-signature"
  FILE_URL = "https://getbook.kobo.com/synthetic/book.epub?token=synthetic-file-token"

  def setup_kobo_household
    @kobo_cache = Dir.mktmpdir("kobo-cache")
    @previous_cache = ENV["KOBO_ACCOUNT_CACHE_PATH"]
    ENV["KOBO_ACCOUNT_CACHE_PATH"] = @kobo_cache
    @owner = users(:one)
    @recipient = users(:two)
    @account = connect_kobo_account(user: @owner, name: "Family purchases")
    @shared_book = @account.kobo_account_books.create!(entitlement_id: "11111111-2222-3333-4444-555555555555",
      revision_id: "edition-1", title: "A Shared Purchase", author: "An Author", ownership_type: "purchased",
      rights: "drm_free", download_format: "EPUB3", download_size: synthetic_epub.bytesize, rights_checked_at: Time.current)
  end

  def teardown_kobo_household
    ENV["KOBO_ACCOUNT_CACHE_PATH"] = @previous_cache
    FileUtils.rm_rf(@kobo_cache) if @kobo_cache
  end

  def share_with(recipient = @recipient, account: @account)
    account.kobo_account_shares.create!(recipient: recipient)
  end

  def synthetic_epub(**options)
    @synthetic_epubs ||= {}
    @synthetic_epubs[options] ||= begin
      path = File.join(Dir.mktmpdir("kobo-epub"), "book.epub")
      write_epub(path, **options)
      File.binread(path)
    end
  end

  def download_entries(url: DOWNLOAD_URL, size: synthetic_epub.bytesize, drm: "SignedNoDrm")
    [ { "Format" => "EPUB3", "DrmType" => drm, "Platform" => "Generic", "Size" => size, "Url" => url },
      { "Format" => "KEPUB", "DrmType" => "KDRM", "Platform" => "Android", "Size" => size, "Url" => url } ]
  end

  def stub_book_metadata(book = @shared_book, revision: "edition-1", entries: download_entries)
    stub_request(:get, "#{STORE}/v1/library/#{book.entitlement_id}/metadata")
      .with(headers: { "Authorization" => "Bearer synthetic-access" })
      .to_return(body: [ { "EntitlementId" => book.entitlement_id, "RevisionId" => revision, "Title" => book.title,
        "DownloadUrls" => entries } ].to_json)
  end

  def stub_book_download(bytes = synthetic_epub, length: bytes.bytesize)
    stub_request(:get, DOWNLOAD_URL).to_return(status: 302, headers: { "Location" => FILE_URL })
    stub_request(:get, FILE_URL).to_return(body: bytes, headers: { "Content-Length" => length.to_s, "Content-Type" => "application/octet-stream" })
  end

  # Runs a complete prepare as the given viewer, with stubbed Kobo hosts.
  def prepare_copy(book = @shared_book, viewer: @owner, bytes: synthetic_epub)
    stub_book_metadata(book)
    stub_book_download(bytes)
    row = Kobo::BookCache.request!(book, viewer)
    Kobo::BookCache.new(row).call
    row.reload
  end

  def recipient_device(user = @recipient, **attributes)
    device, token = KoboDevice.issue(user: user, name: "Reader of #{user.name}", base_url: "https://shelfarr.example", **attributes)
    device.save!
    [ device, token ]
  end
end
