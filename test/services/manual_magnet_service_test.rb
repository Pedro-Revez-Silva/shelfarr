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
    assert_match /missing a torrent hash/, result.error
  end

  test "reuses the same search result when the same magnet is added twice" do
    magnet = "magnet:?xt=urn:btih:DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF&dn=Dup"

    assert_difference -> { @request.search_results.count }, 1 do
      ManualMagnetService.call(request: @request, magnet_url: magnet)
      ManualMagnetService.call(request: @request, magnet_url: magnet)
    end
  end
end
