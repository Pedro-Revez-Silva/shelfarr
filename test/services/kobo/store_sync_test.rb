# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::StoreSyncTest < ActiveSupport::TestCase
  include KoboTestHelper

  URL = "https://storeapi.kobo.com/v1/library/sync"

  setup do
    prepare_kobo_book
    @device.update!(store_coexistence: true)
    @delivery = @device.send_book!(@book)
    @sync = Kobo::StoreSync.new(@device, endpoint: @device.endpoint(@token))
    @headers = { "authorization" => "Bearer reader-own" }
  end

  teardown { FileUtils.remove_entry(@root) }

  def store_item(id, title = "Store book")
    { "NewEntitlement" => { "BookEntitlement" => { "Id" => id }, "BookMetadata" => { "Title" => title } } }
  end

  test "Shelfarr selections come first, then the reader's own Store pages with a combined cursor" do
    stub_request(:get, URL).with { |request| request.headers["X-Kobo-Synctoken"].nil? && request.headers["Authorization"] == "Bearer reader-own" }
      .to_return(body: [ store_item("store-1") ].to_json, headers: { "X-Kobo-Synctoken" => "store-page-2", "X-Kobo-Sync" => "continue", "X-Kobo-Recent-Reads" => "r" })
    first = @sync.call(nil, headers: @headers)
    assert_equal [ @delivery.entitlement_id, "store-1" ], first.items.map { |item| item.values.first["BookEntitlement"]["Id"] }
    assert first.more
    assert_equal({ "x-kobo-recent-reads" => "r" }, first.headers)
    assert_equal "ok", @device.reload.store_status

    stub_request(:get, URL).with(headers: { "X-Kobo-Synctoken" => "store-page-2" })
      .to_return(body: [ store_item("store-2") ].to_json, headers: { "X-Kobo-Synctoken" => "store-done" })
    second = @sync.call(first.token, headers: @headers)
    assert_equal [ "store-2" ], second.items.map { |item| item.values.first["BookEntitlement"]["Id"] }
    assert_not second.more
    assert_equal "store-done", Kobo::SyncCursor.new(@device).read(second.token).store
  end

  test "a Store outage or unusable page keeps Shelfarr books and does not advance the Store cursor" do
    start = Kobo::SyncCursor.new(@device).write(local: nil, store: "store-before")
    [ -> { stub_request(:get, URL).to_return(status: 503) }, -> { stub_request(:get, URL).to_timeout },
      -> { stub_request(:get, URL).to_return(body: "{}", headers: { "X-Kobo-Synctoken" => "next" }) },
      -> { stub_request(:get, URL).to_return(body: "not json", headers: { "X-Kobo-Synctoken" => "next" }) },
      -> { stub_request(:get, URL).to_return(body: "[]") },
      -> { stub_request(:get, URL).to_return(status: 302, headers: { "Location" => "https://evil.example" }) } ].each do |failure|
      WebMock.reset!
      failure.call
      result = @sync.call(start, headers: @headers)
      assert_equal [ @delivery.entitlement_id ], result.items.map { |item| item.values.first["BookEntitlement"]["Id"] }
      assert_equal "store-before", Kobo::SyncCursor.new(@device).read(result.token).store
      assert_equal "unavailable", @device.reload.store_status
    end
  end

  test "other Store refusals keep Shelfarr books and are reported separately from outages" do
    stub_request(:get, URL).to_return(status: 400, body: { ResponseStatus: {} }.to_json)
    result = @sync.call(nil, headers: @headers)
    assert_equal [ @delivery.entitlement_id ], result.items.map { |item| item.values.first["BookEntitlement"]["Id"] }
    assert_equal "rejected", @device.reload.store_status
  end

  test "the reader's expired Kobo sign-in is passed back so the reader refreshes it" do
    stub_request(:get, URL).to_return(status: 401, headers: { "WWW-Authenticate" => "Bearer" })
    response = @sync.call(nil, headers: @headers)
    assert_kind_of Kobo::StoreProxy::Response, response
    assert_equal 401, response.status
    assert_equal "authorization", @device.reload.store_status
  end

  test "Store records cannot replace, remove or change state for a Shelfarr selection" do
    id = @delivery.entitlement_id
    stub_request(:get, URL).to_return(headers: { "X-Kobo-Synctoken" => "t" }, body: [
      { "ChangedEntitlement" => { "BookEntitlement" => { "Id" => id, "IsRemoved" => true } } },
      { "ChangedReadingState" => { "ReadingState" => { "EntitlementId" => id } } },
      store_item("store-1"), { "NewTag" => { "Tag" => { "Id" => "tag" } } } ].to_json)
    items = @sync.call(nil, headers: @headers).items
    assert_equal 1, items.count { |item| item.to_json.include?(id) }
    assert items.any? { |item| item.key?("NewTag") }
    assert items.any? { |item| item.to_json.include?("store-1") }
  end

  test "a page of Shelfarr books is completed before asking the Store" do
    101.times do |index|
      path = File.join(@root, "Book #{index}.epub")
      write_epub(path)
      @device.send_book!(Book.create!(title: "Book #{index}", book_type: :ebook, file_path: path))
    end
    first = @sync.call(nil, headers: @headers)
    assert first.more
    assert_equal KoboSync::PAGE_SIZE, first.items.size
    assert_not_requested :get, URL
    stub_request(:get, URL).to_return(body: "[]", headers: { "X-Kobo-Synctoken" => "store-1" })
    second = @sync.call(first.token, headers: @headers)
    assert_equal 2, second.items.size
    assert_requested :get, URL, times: 1
  end
end
