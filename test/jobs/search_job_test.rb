# frozen_string_literal: true

require "test_helper"

class SearchJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-key")
  end

  test "updates request status to searching" do
    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.searching?
    end
  end

  test "creates search results from Prowlarr response" do
    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.searching?
      assert @request.search_results.any?
      assert_equal "Test Result Book", @request.search_results.first.title
    end
  end

  test "schedules retry when no results found" do
    VCR.turned_off do
      stub_prowlarr_search_empty

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.not_found?
      assert @request.next_retry_at.present?
    end
  end

  test "marks for attention when no search sources configured" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, false)

    SearchJob.perform_now(@request.id)
    @request.reload

    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search sources configured"
  end

  test "skips non-pending requests" do
    @request.update!(status: :searching)

    SearchJob.perform_now(@request.id)
    @request.reload

    # Status should not change
    assert @request.searching?
  end

  test "skips non-existent requests" do
    # Should not raise error
    assert_nothing_raised do
      SearchJob.perform_now(999999)
    end
  end

  test "includes audiobook in search query for audiobook requests" do
    audiobook_book = books(:audiobook_acquired)
    request = Request.create!(book: audiobook_book, user: users(:one), status: :pending)

    VCR.turned_off do
      # Stub that verifies "audiobook" is in the query
      stub_request(:get, %r{localhost:9696/api/v1/search.*audiobook}i)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(request.id)
      end
    end
  end

  private

  def stub_prowlarr_search_with_results
    stub_request(:get, %r{localhost:9696/api/v1/search})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [
          {
            "guid" => "test-guid-123",
            "title" => "Test Result Book",
            "indexer" => "TestIndexer",
            "size" => 52428800,
            "seeders" => 25,
            "leechers" => 5,
            "downloadUrl" => "http://example.com/download",
            "magnetUrl" => "magnet:?xt=urn:btih:test123",
            "infoUrl" => "http://example.com/info",
            "publishDate" => "2024-01-15T10:00:00Z"
          }
        ].to_json
      )
  end

  def stub_prowlarr_search_empty
    stub_request(:get, %r{localhost:9696/api/v1/search})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [].to_json
      )
  end
end
