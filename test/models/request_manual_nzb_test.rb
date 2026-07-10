# frozen_string_literal: true

require "test_helper"

class RequestManualNzbTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @request = requests(:pending_request)
  end

  test "add_manual_nzb creates a selected usenet result and queued download" do
    @request.update!(
      status: :not_found,
      next_retry_at: 1.hour.from_now,
      attention_needed: true,
      issue_description: "Previous search failed"
    )
    url = "https://user:password@nzb.example/download?id=42&X-Amz-Signature=very-secret"

    assert_enqueued_with(job: DownloadJob) do
      assert_difference [ "SearchResult.count", "Download.count" ], 1 do
        @request.add_manual_nzb!("  #{url}  ")
      end
    end

    result = @request.search_results.find_by!(source: SearchResult::SOURCE_MANUAL_NZB)
    download = @request.downloads.order(:created_at).last

    assert_equal url, result.download_url
    assert_equal "manual-nzb:#{Digest::SHA256.hexdigest(url)}", result.guid
    assert_not_includes result.guid, "very-secret"
    assert_equal "Manual NZB", result.indexer
    assert_nil result.magnet_url
    assert_nil result.seeders
    assert_nil result.leechers
    assert result.usenet?
    assert result.selected?
    assert_equal result, download.search_result
    assert download.queued?

    @request.reload
    assert @request.downloading?
    assert_nil @request.next_retry_at
    assert_not @request.attention_needed?
    assert_nil @request.issue_description
  end

  test "add_manual_nzb accepts opaque signed URLs without an NZB suffix" do
    url = "https://downloads.example/api/release/123?token=opaque-value"

    assert_enqueued_with(job: DownloadJob) do
      @request.add_manual_nzb!(url)
    end

    assert_equal url, @request.search_results.find_by!(source: SearchResult::SOURCE_MANUAL_NZB).download_url
  end

  test "add_manual_nzb rejects blank relative hostless and non HTTP URLs" do
    invalid_urls = [
      "",
      "/downloads/book.nzb",
      "https:///downloads/book.nzb",
      "ftp://example.com/book.nzb",
      "file:///tmp/book.nzb",
      "magnet:?xt=urn:btih:#{'a' * 40}",
      "javascript:alert(1)"
    ]

    assert_no_difference [ "SearchResult.count", "Download.count" ] do
      invalid_urls.each do |url|
        assert_raises(ArgumentError, match: /valid HTTP\(S\) NZB URL/) do
          @request.add_manual_nzb!(url)
        end
      end
    end
  end

  test "add_manual_nzb reuses the result for the exact same URL" do
    url = "https://downloads.example/release?id=123&token=same-token"
    @request.add_manual_nzb!(url)

    assert_no_difference "SearchResult.count" do
      assert_difference "Download.count", 1 do
        @request.add_manual_nzb!(url)
      end
    end

    results = @request.search_results.where(source: SearchResult::SOURCE_MANUAL_NZB)
    assert_equal 1, results.count
    assert_equal "manual-nzb:#{Digest::SHA256.hexdigest(url)}", results.first.guid
    assert results.first.selected?
  end

  test "add_manual_nzb rejects completed requests" do
    @request.complete!

    assert_raises(ArgumentError, match: /completed request/) do
      @request.add_manual_nzb!("https://downloads.example/book.nzb")
    end
  end

  test "add_manual_nzb rejects processing requests" do
    @request.update!(status: :processing)

    assert_raises(ArgumentError, match: /post-processing/) do
      @request.add_manual_nzb!("https://downloads.example/book.nzb")
    end
  end

  test "manual download allows a downloading override but not processing" do
    @request.update!(status: :downloading)
    assert @request.manual_download_allowed?
    assert @request.manual_nzb_allowed?
    assert @request.manual_magnet_allowed?

    @request.update!(status: :processing)
    assert_not @request.manual_download_allowed?
    assert_not @request.manual_nzb_allowed?
    assert_not @request.manual_magnet_allowed?
  end
end
