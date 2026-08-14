# frozen_string_literal: true

require "test_helper"

class RankingProviderClientTest < ActiveSupport::TestCase
  setup do
    @provider = RankingProvider.create!(
      name: "Local Media Ranker",
      url: "http://ranker.test",
      api_key: "secret",
      timeout_seconds: 5
    )
    @client = @provider.client
    @request = requests(:pending_request)
    @request.update!(request_scope: "collection", collection_title: "Example Series")
    @request.book.update!(
      release_date: Date.new(2019, 4, 2),
      publisher: "Example Press",
      series: "Example Series",
      series_position: "2",
      narrator: "Example Narrator",
      description: "Enough local context to disambiguate the requested work.",
      isbn: "9781234567890",
      metadata_source: "hardcover",
      hardcover_id: "hc-123"
    )
  end

  test "rank sends versioned media-neutral context and safe candidates" do
    results = [
      @request.search_results.create!(
        guid: "prowlarr-rank",
        title: "Prowlarr Candidate [EPUB]",
        source: SearchResult::SOURCE_PROWLARR,
        indexer: "Books Indexer",
        download_url: "https://secret.test/download?id=token",
        info_url: "https://secret.test/details",
        confidence_score: 71,
        score_breakdown: { "title" => 100, "search_attempt" => "exact_title", "extensions" => [ "epub" ] }
      ),
      @request.search_results.create!(
        guid: "anna-rank",
        title: "Anna Candidate [PDF]",
        source: SearchResult::SOURCE_ANNA_ARCHIVE,
        confidence_score: 68,
        score_breakdown: { "title" => 80, "extensions" => [ "pdf" ] }
      )
    ]

    VCR.turned_off do
      stub_request(:post, "http://ranker.test/v1/rank")
        .with do |request|
          body = JSON.parse(request.body)
          media = body.fetch("media")
          candidates = body.fetch("candidates")

          request.headers["Authorization"] == "Bearer secret" &&
            body["schema_version"] == 1 &&
            body["task"] == "candidate_ranking" &&
            media["type"] == "book" &&
            media["format"] == "ebook" &&
            media["title"] == @request.book.title &&
            media["contributors"].include?({ "role" => "author", "name" => @request.book.author }) &&
            media["contributors"].include?({ "role" => "narrator", "name" => "Example Narrator" }) &&
            media["relationships"] == [ { "type" => "series", "name" => "Example Series", "position" => "2" } ] &&
            media.dig("identifiers", "isbn") == [ "9781234567890" ] &&
            media.dig("identifiers", "hardcover") == [ "hc-123" ] &&
            !media.key?("cover_url") &&
            body.dig("context", "collection", "title") == "Example Series" &&
            body.dig("preferences", "preferred_download_types").is_a?(Array) &&
            candidates.map { |candidate| candidate["source"] } == %w[prowlarr anna_archive] &&
            candidates.first["candidate_id"] == results.first.id.to_s &&
            candidates.first["application_score"] == 71 &&
            candidates.first.dig("application_score_breakdown", "search_attempt") == "exact_title" &&
            candidates.first["detected_formats"] == [ "epub" ] &&
            candidates.none? { |candidate| candidate.key?("download_url") || candidate.key?("magnet_url") || candidate.key?("info_url") || candidate.key?("provider_payload") }
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            schema_version: 1,
            rankings: [
              {
                candidate_id: results.last.id.to_s,
                rank_score: 96,
                match_evidence: { matched_fields: %w[title author] }
              }
            ]
          }.to_json
        )

      rankings = @client.rank(@request, results)

      assert_equal 1, rankings.size
      assert_equal results.last.id.to_s, rankings.first.candidate_id
      assert_equal 96, rankings.first.rank_score
      assert_equal %w[title author], rankings.first.match_evidence["matched_fields"]
    end
  end

  test "rank ignores malformed entries and out-of-range scores" do
    VCR.turned_off do
      stub_request(:post, "http://ranker.test/v1/rank")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            rankings: [
              { candidate_id: "valid", rank_score: 75 },
              { candidate_id: "too-high", rank_score: 101 },
              { rank_score: 50 },
              "invalid"
            ]
          }.to_json
        )

      assert_equal [ "valid" ], @client.rank(@request, []).map(&:candidate_id)
    end
  end

  test "rank rejects an invalid response shape" do
    VCR.turned_off do
      stub_request(:post, "http://ranker.test/v1/rank")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { results: [] }.to_json)

      assert_raises(RankingProviderClient::ResponseError) { @client.rank(@request, []) }
    end
  end

  test "test connection calls health endpoint" do
    VCR.turned_off do
      stub_request(:get, "http://ranker.test/health").to_return(status: 204)
      assert @client.test_connection
    end
  end
end
