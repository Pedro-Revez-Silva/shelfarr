# frozen_string_literal: true

require "test_helper"

class ManualMagnetServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @request = requests(:pending_request)
  end

  test "creates a selected search result from a magnet link" do
    magnet = "magnet:?xt=urn:btih:DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF&dn=The+Perfect+Run"

    result = nil
    assert_enqueued_with(job: DownloadJob) do
      result = ManualMagnetService.call(request: @request, magnet_url: magnet)
    end

    assert result.success?
    assert_equal "The Perfect Run", result.search_result.title
    assert_equal magnet, result.search_result.magnet_url
    assert_equal "Manual", result.search_result.indexer
    assert_equal SearchResult::SOURCE_MANUAL, result.search_result.source
    assert result.search_result.from_manual?
    assert_not result.search_result.from_indexer?
    assert result.search_result.selected?
    assert_equal @request, result.download.request
  end

  test "falls back to the book title when the magnet has no display name" do
    magnet = "magnet:?xt=urn:btih:DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"

    result = ManualMagnetService.call(request: @request, magnet_url: magnet)

    assert result.success?
    assert_equal @request.book.title, result.search_result.title
  end

  test "rejects blank input" do
    result = ManualMagnetService.call(request: @request, magnet_url: "  ")

    assert_not result.success?
    assert_match /provide a magnet link/, result.error
  end

  test "rejects non-magnet URLs" do
    result = ManualMagnetService.call(request: @request, magnet_url: "https://example.com/file.torrent")

    assert_not result.success?
    assert_match /doesn't look like a magnet link/, result.error
  end

  test "rejects magnet links without a torrent hash" do
    result = ManualMagnetService.call(request: @request, magnet_url: "magnet:?dn=No+Hash+Here")

    assert_not result.success?
    assert_match /no valid torrent hash/, result.error
  end

  test "rejects a malformed or truncated torrent hash" do
    # "abc" is neither a 40-char hex nor a 32-char base32 hash; reject up front
    # instead of dispatching a bad magnet that the torrent client rejects later.
    result = ManualMagnetService.call(request: @request, magnet_url: "magnet:?xt=urn:btih:abc")

    assert_not result.success?
    assert_match /no valid torrent hash/, result.error
  end

  test "refuses to add a magnet to an already-completed request" do
    @request.update!(status: :completed)
    magnet = "magnet:?xt=urn:btih:DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"

    assert_no_difference -> { Download.count } do
      result = ManualMagnetService.call(request: @request, magnet_url: magnet)
      assert_not result.success?
      assert_match /already completed/, result.error
    end

    assert @request.reload.completed?
  end

  test "reuses the same search result when the same magnet is added twice" do
    magnet = "magnet:?xt=urn:btih:DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF&dn=Dup"

    assert_difference -> { @request.search_results.count }, 1 do
      ManualMagnetService.call(request: @request, magnet_url: magnet)
      ManualMagnetService.call(request: @request, magnet_url: magnet)
    end
  end

  test "dedupes hex and base32 forms of the same info hash" do
    # 32 'A's in base32 decodes to 20 zero bytes -> 40 hex zeros, the same
    # torrent as the all-zero hex magnet. Both must collapse to one guid.
    hex_magnet = "magnet:?xt=urn:btih:#{'0' * 40}"
    base32_magnet = "magnet:?xt=urn:btih:#{'A' * 32}"

    assert_difference -> { @request.search_results.count }, 1 do
      first = ManualMagnetService.call(request: @request, magnet_url: hex_magnet)
      second = ManualMagnetService.call(request: @request, magnet_url: base32_magnet)
      assert first.success?
      assert second.success?
      assert_equal first.search_result.id, second.search_result.id
    end
  end
end
