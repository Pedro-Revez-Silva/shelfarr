# frozen_string_literal: true

require "test_helper"

class RequestManualMagnetTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @request = requests(:pending_request)
  end

  test "add_manual_magnet creates manual search result and download" do
    @request.update!(status: :not_found, next_retry_at: 1.hour.from_now)
    magnet = "magnet:?xt=urn:btih:#{'c' * 40}&dn=Manual"

    assert_enqueued_with(job: DownloadJob) do
      assert_difference [ "SearchResult.count", "Download.count" ], 1 do
        @request.add_manual_magnet!(magnet)
      end
    end

    result = @request.search_results.find_by!(source: SearchResult::SOURCE_MANUAL_MAGNET)
    download = @request.downloads.order(:created_at).last

    assert_equal magnet, result.magnet_url
    assert_equal "Manual Magnet", result.indexer
    assert result.selected?
    assert @request.reload.downloading?
    assert_nil @request.next_retry_at
    assert_equal result, download.search_result
    assert download.queued?
  end

  test "add_manual_magnet rejects non magnet links" do
    assert_raises(ArgumentError, match: /valid magnet/) do
      @request.add_manual_magnet!("https://example.com/file.torrent")
    end
  end

  test "add_manual_magnet rejects magnet links without a valid info hash" do
    assert_raises(ArgumentError, match: /info hash/) do
      @request.add_manual_magnet!("magnet:?xt=urn:btih:tooshort")
    end

    assert_raises(ArgumentError, match: /info hash/) do
      @request.add_manual_magnet!("magnet:?dn=No+Hash+Here")
    end
  end

  test "add_manual_magnet dedups magnets with the same info hash" do
    hash = "f" * 40
    @request.add_manual_magnet!("magnet:?xt=urn:btih:#{hash}&dn=First&tr=http://tracker-a.example")

    updated_magnet = "magnet:?xt=urn:btih:#{hash}&dn=Second&tr=http://tracker-b.example"
    assert_no_difference "SearchResult.count" do
      @request.add_manual_magnet!(updated_magnet)
    end

    result = @request.search_results.find_by!(source: SearchResult::SOURCE_MANUAL_MAGNET)
    assert_equal "manual-magnet:#{hash}", result.guid
    assert_equal updated_magnet, result.magnet_url
  end

  test "add_manual_magnet dedups hex and base32 encodings of the same info hash" do
    @request.add_manual_magnet!("magnet:?xt=urn:btih:#{'aa' * 20}")

    assert_no_difference "SearchResult.count" do
      @request.add_manual_magnet!("magnet:?xt=urn:btih:#{'VK' * 16}")
    end
  end

  test "add_manual_magnet rejects completed requests" do
    @request.complete!

    assert_raises(ArgumentError, match: /completed request/) do
      @request.add_manual_magnet!("magnet:?xt=urn:btih:#{'d' * 40}")
    end
  end

  test "add_manual_magnet rejects processing requests" do
    @request.update!(status: :processing)

    assert_raises(ArgumentError, match: /post-processing/) do
      @request.add_manual_magnet!("magnet:?xt=urn:btih:#{'e' * 40}")
    end
  end

  test "manual_magnet_allowed allows downloading override but not processing" do
    @request.update!(status: :downloading)
    assert @request.manual_magnet_allowed?

    @request.update!(status: :processing)
    assert_not @request.manual_magnet_allowed?
  end
end
