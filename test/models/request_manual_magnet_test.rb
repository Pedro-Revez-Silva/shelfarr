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

  test "add_manual_magnet rejects completed requests" do
    @request.complete!

    assert_raises(ArgumentError, match: /completed request/) do
      @request.add_manual_magnet!("magnet:?xt=urn:btih:#{'d' * 40}")
    end
  end
end
