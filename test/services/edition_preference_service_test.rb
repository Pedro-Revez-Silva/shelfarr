# frozen_string_literal: true

require "test_helper"

class EditionPreferenceServiceTest < ActiveSupport::TestCase
  setup do
    @request = Request.new(book: books(:ebook_pending), request_scope: "collection")
    @older = result(edition_year: 2005)
    @newer = result(edition_year: 2020)
  end

  test "prefers the most recent known edition among equally suitable candidates" do
    newest = result(edition_year: Date.current.year)

    assert_same newest, preferred(@older, @newer, newest)
  end

  test "keeps existing ordering for equal edition years" do
    assert_same @older, preferred(@older, result(edition_year: 2005))
  end

  test "keeps ordinary single-book requests unchanged" do
    @request.request_scope = "single"

    assert_same @older, preferred(@older, @newer)
  end

  test "does not apply book edition preference to comic issues" do
    @request.book = Book.new(book_type: :comicbook)

    assert_same @older, preferred(@older, @newer)
  end

  test "does not replace a leading result of unknown edition" do
    @older.provider_payload = {}

    assert_same @older, preferred(@older, @newer)
  end

  test "unknown editions do not prevent comparing later known editions" do
    assert_same @newer, preferred(@older, result, @newer)
  end

  test "never treats upload timestamps or generic years as edition evidence" do
    @newer.provider_payload = { "published_at" => Time.current.iso8601, "year" => 2020 }
    @newer.published_at = Time.current
    @newer.title = "Test Book (2020)"

    assert_same @older, preferred(@older, @newer)
  end

  test "does not trust inferred Anna Archive years or indexer publication payloads" do
    [ SearchResult::SOURCE_ANNA_ARCHIVE, SearchResult::SOURCE_PROWLARR ].each do |source|
      @newer.source = source

      assert_same @older, preferred(@older, @newer)
    end
  end

  test "accepts an explicit edition year from a custom provider" do
    @newer.source = SearchResult::SOURCE_CUSTOM
    @newer.provider_payload = { "download_type" => "direct", "edition_year" => "2020" }

    assert_same @newer, preferred(@older, @newer)
  end

  test "rejects malformed and future edition years" do
    [ nil, "", "2020 edition", "2020-01-01", 2020.5, 0, true, [], {}, Date.current.year + 1 ].each do |year|
      @newer.provider_payload = { "edition_year" => year }

      assert_same @older, preferred(@older, @newer), "Unexpectedly preferred year #{year.inspect}"
    end
  end

  test "malformed provider payload does not interrupt selection" do
    @newer.provider_payload = []

    assert_same @older, preferred(@older, @newer)
  end

  test "edition recency cannot override confidence or download type preferences" do
    @newer.confidence_score = 89
    assert_same @older, preferred(@older, @newer)

    @newer.confidence_score = @older.confidence_score
    @newer.source = SearchResult::SOURCE_CUSTOM
    @newer.provider_payload = { "download_type" => "usenet", "edition_year" => 2020 }
    assert_same @older, preferred(@older, @newer)
  end

  test "edition recency cannot trade title certainty language or quality for an equal score" do
    [ "title", "author", "language", "format", "preference_adjustment", "audio_bitrate_kbps" ].each do |component|
      @newer.score_breakdown = @older.score_breakdown.merge(component => 0)
      assert_same @older, preferred(@older, @newer), "Overrode #{component}"
    end

    @newer.score_breakdown = @older.score_breakdown
    @newer.detected_language = nil
    assert_same @older, preferred(@older, @newer)
  end

  test "handles no candidates" do
    assert_nil preferred
  end

  private

  def preferred(*candidates)
    EditionPreferenceService.call(request: @request, candidates: candidates)
  end

  def result(edition_year: nil)
    SearchResult.new(
      source: SearchResult::SOURCE_ZLIBRARY,
      confidence_score: 95,
      detected_language: "en",
      provider_payload: { "edition_year" => edition_year }.compact,
      score_breakdown: { "title" => 100, "author" => 100, "language" => 100, "format" => 100,
                         "preference_adjustment" => 10, "audio_bitrate_kbps" => 128 }
    )
  end
end
