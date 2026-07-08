# frozen_string_literal: true

require "test_helper"

class ComicVineClientTest < ActiveSupport::TestCase
  setup do
    @original_enabled = SettingsService.get(:comic_vine_enabled)
    @original_api_key = SettingsService.get(:comic_vine_api_key)
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "comic-key")
  end

  teardown do
    SettingsService.set(:comic_vine_enabled, @original_enabled.nil? ? true : @original_enabled)
    SettingsService.set(:comic_vine_api_key, @original_api_key.to_s)
  end

  test "details fetches comic vine issue metadata" do
    VCR.turned_off do
      stub_request(:get, %r{comicvine\.gamespot\.com/api/issue/4000-123/})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "status_code" => 1,
            "results" => issue_payload("123", "1", "Series One", "Issue One")
          }.to_json
        )

      result = ComicVineClient.details("comic_vine:4000-123", content_kind: "comic")

      assert_equal "4000-123", result.resource_key
      assert_equal "Series One - #1 - Issue One", result.title
      assert_equal "4050-99", result.collection_id
      assert_equal "Series One", result.collection_title
      assert_equal "comic", result.content_kind
    end
  end

  test "volume_issues fetches and normalizes issues for a volume" do
    VCR.turned_off do
      stub_request(:get, %r{comicvine\.gamespot\.com/api/issues/})
        .with(query: hash_including("filter" => "volume:99", "limit" => "2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "status_code" => 1,
            "number_of_total_results" => 2,
            "results" => [
              issue_payload("123", "1", "Series One", "Issue One"),
              issue_payload("124", "2", "Series One", "Issue Two")
            ]
          }.to_json
        )

      issues = ComicVineClient.volume_issues("4050-99", limit: 2, content_kind: "manga")

      assert_equal 2, issues.size
      assert_equal "4000-123", issues.first.resource_key
      assert_equal "2", issues.second.issue_number
      assert_equal "manga", issues.second.content_kind
    end
  end

  test "volume_issues returns empty for non-positive limits" do
    VCR.turned_off do
      assert_equal [], ComicVineClient.volume_issues("4050-99", limit: 0)
      assert_not_requested :get, %r{comicvine\.gamespot\.com/api/issues/}
    end
  end

  private

  def issue_payload(id, number, volume_name, name)
    {
      "id" => id,
      "name" => name,
      "issue_number" => number,
      "cover_date" => "2020-01-01",
      "description" => "<p>Issue description</p>",
      "image" => { "super_url" => "https://example.com/#{id}.jpg" },
      "site_detail_url" => "https://comicvine.gamespot.com/issue/4000-#{id}/",
      "volume" => { "id" => 99, "name" => volume_name },
      "person_credits" => [ { "name" => "Writer One" } ]
    }
  end
end
