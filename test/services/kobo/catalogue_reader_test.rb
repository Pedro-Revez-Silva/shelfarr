# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_account_test_helper"

class Kobo::CatalogueReaderTest < ActiveSupport::TestCase
  include KoboAccountTestHelper

  setup { @account = connect_kobo_account }

  test "reads every page and retains only bounded catalogue metadata" do
    stub_request(:get, STORE + "/v1/library/sync").with { |request| request.headers["X-Kobo-Synctoken"].nil? }
      .to_return(body: [ kobo_book ].to_json, headers: { "x-kobo-sync" => "continue", "x-kobo-synctoken" => "next-page" })
    stub_request(:get, STORE + "/v1/library/sync").with(headers: { "x-kobo-synctoken" => "next-page" })
      .to_return(body: [ kobo_book(id: "book-2", title: "Second", origin: "Subscription") ].to_json)
    entries = Kobo::CatalogueReader.new(@account).call
    assert_equal [ "owned-book-1", "book-2" ], entries.pluck(:entitlement_id)
    assert_equal "purchased", entries.first.fetch(:ownership_type)
    assert_equal "subscription", entries.last.fetch(:ownership_type)
    assert_equal "ebook", entries.first.fetch(:media_type)
    assert_not_includes entries.to_s, "private-book-url"
    assert_not_requested :get, /content|download|keys/
  end

  test "a 401 refreshes credentials once and retries the same page with the new token" do
    stub_request(:get, STORE + "/v1/library/sync").with(headers: { "Authorization" => "Bearer synthetic-access" }).to_return(status: 401)
    stub_request(:post, STORE + "/v1/auth/refresh").with(body: hash_including("RefreshToken" => "synthetic-refresh"))
      .to_return(body: kobo_tokens(access: "new-access", refresh: "new-refresh"))
    stub_request(:get, STORE + "/v1/library/sync").with(headers: { "Authorization" => "Bearer new-access" })
      .to_return(body: [ kobo_book ].to_json)
    assert_equal 1, Kobo::CatalogueReader.new(@account).call.size
    assert_equal "new-access", @account.reload.access_token
    assert_equal "new-refresh", @account.refresh_token
    assert_requested :post, STORE + "/v1/auth/refresh", times: 1
  end

  test "a repeated 401 does not loop or discard local credentials" do
    stub_request(:get, STORE + "/v1/library/sync").to_return(status: 401)
    stub_request(:post, STORE + "/v1/auth/refresh").to_return(body: kobo_tokens(access: "new-access"))
    assert_equal "credentials_expired", assert_raises(Kobo::HttpClient::Error) { Kobo::CatalogueReader.new(@account).call }.code
    assert_requested :post, STORE + "/v1/auth/refresh", times: 1
    assert_requested :get, STORE + "/v1/library/sync", times: 2
    assert_equal "new-access", @account.reload.access_token
  end

  test "repeating continuation tokens and unbounded metadata fail rather than publishing a partial catalogue" do
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: [ kobo_book ].to_json,
      headers: { "x-kobo-sync" => "continue", "x-kobo-synctoken" => "same-page" })
    assert_raises(Kobo::HttpClient::Error) { Kobo::CatalogueReader.new(@account).call }
    stub_kobo_catalogue(items: [ kobo_book(title: "x" * 4097) ])
    assert_raises(Kobo::HttpClient::Error) { Kobo::CatalogueReader.new(@account).call }
    assert_equal 0, @account.kobo_account_books.count
  end

  test "missing authors removals unknown ownership and audiobooks are represented honestly" do
    audio = kobo_book(origin: "Unrecognized")
    audio["NewEntitlement"]["BookMetadata"].merge!("Contributors" => nil, "ContentType" => "AudioBook")
    removed = { "ChangedEntitlement" => { "BookEntitlement" => { "Id" => "old-book", "IsRemoved" => true } } }
    stub_kobo_catalogue(items: [ audio, removed, { "ChangedReadingState" => {} } ])
    entries = Kobo::CatalogueReader.new(@account).call
    assert_equal "", entries.first.fetch(:author)
    assert_equal "audiobook", entries.first.fetch(:media_type)
    assert_equal "unknown", entries.first.fetch(:ownership_type)
    assert_equal({ entitlement_id: "old-book", archived: true }, entries.last)
  end

  test "valid non-ASCII UTF-8 titles survive binary HTTP responses unchanged" do
    title = "O coração · 海辺の本"
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: [ kobo_book(title: title) ].to_json.b)
    assert_equal title, Kobo::CatalogueReader.new(@account).call.sole.fetch(:title)
  end
end
