# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboSyncCursorProxyTest < ActionDispatch::IntegrationTest
  include KoboTestHelper

  STORE = "https://storeapi.kobo.com"

  setup do
    prepare_kobo_book
    @delivery = @device.send_book!(@book)
    @base = "/kobo/#{@token}"
  end

  teardown { FileUtils.remove_entry(@root) }

  def coexist!
    @device.update!(store_coexistence: true)
  end

  def kobo_headers
    { "Authorization" => "Bearer reader-own-kobo" }
  end

  test "a large Store continuation fits proxy headers and is forwarded intact on the next page" do
    coexist!
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    store = SecureRandom.urlsafe_base64(3_000)
    stub_request(:get, "#{STORE}/v1/library/sync").with { |request| request.headers["X-Kobo-Synctoken"].nil? }
      .to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Synctoken" => store, "X-Kobo-Sync" => "continue" }, body: "[]")
    get "#{@base}/v1/library/sync", headers: kobo_headers
    assert_response :success
    cursor = response.headers.fetch("x-kobo-synctoken")
    assert_operator cursor.bytesize, :<=, 3.kilobytes
    assert_equal "continue", response.headers["x-kobo-sync"]
    assert_equal @delivery.entitlement_id, response.parsed_body.sole.dig("NewEntitlement", "BookEntitlement", "Id")

    stub_request(:get, "#{STORE}/v1/library/sync").with(headers: { "X-Kobo-Synctoken" => store })
      .to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Synctoken" => "done" }, body: "[]")
    get "#{@base}/v1/library/sync", headers: kobo_headers.merge("X-Kobo-Synctoken" => cursor)
    assert_response :success
    assert_empty response.parsed_body
    assert_requested :get, "#{STORE}/v1/library/sync", headers: { "X-Kobo-Synctoken" => store }, times: 1

    Rails.cache.clear
    get "#{@base}/v1/library/sync", headers: kobo_headers.merge("X-Kobo-Synctoken" => cursor)
    assert_response :success
    assert_empty response.parsed_body, "losing the Store cache must not replay the local book"
  ensure
    Rails.cache = previous
  end

  test "sync returns a retryable failure when a large continuation cannot be retained" do
    coexist!
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::NullStore.new
    stub_request(:get, "#{STORE}/v1/library/sync")
      .to_return(headers: { "Content-Type" => "application/json", "X-Kobo-Synctoken" => SecureRandom.urlsafe_base64(3_000) }, body: "[]")
    get "#{@base}/v1/library/sync", headers: kobo_headers
    assert_response :service_unavailable
    assert_nil response.headers["x-kobo-synctoken"]
  ensure
    Rails.cache = previous
  end
end
