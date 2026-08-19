# frozen_string_literal: true

require "test_helper"

class AutoSelectServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @book = books(:ebook_pending)
    @user = users(:one)
    @request = Request.create!(
      book: @book,
      user: @user,
      status: :searching,
      language: "en"
    )

    Setting.find_or_create_by(key: "auto_select_confidence_threshold").update!(
      value: "50",
      value_type: "integer",
      category: "auto_select"
    )

    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
  end

  test "selects best downloadable result meeting seeder threshold" do
    result = create_search_result(seeders: 10, magnet_url: "magnet:?test")

    assert_enqueued_with(job: DownloadJob) do
      selection = AutoSelectService.call(@request)

      assert selection.success?
      assert_equal :auto_selected, selection.reason
      assert_equal result, selection.search_result
    end

    assert result.reload.selected?
    assert @request.reload.downloading?
    assert_equal 1, @request.downloads.count
  end

  test "skips when no downloadable results" do
    # Result without download link or magnet
    create_search_result(seeders: 10)

    selection = AutoSelectService.call(@request)

    refute selection.success?
    assert_equal :no_downloadable_results, selection.reason
    assert @request.reload.searching?
    assert_equal 0, @request.downloads.count
  end

  test "skips when best result below seeder threshold" do
    Setting.find_or_create_by(key: "auto_select_min_seeders").update!(
      value: "5",
      value_type: "integer",
      category: "auto_select"
    )

    result = create_search_result(seeders: 2, magnet_url: "magnet:?test")

    selection = AutoSelectService.call(@request)

    refute selection.success?
    assert_equal :below_seeder_threshold, selection.reason
    assert_equal result, selection.search_result
    assert result.reload.pending?
    assert @request.reload.searching?
  end

  test "usenet results bypass seeder check" do
    Setting.find_or_create_by(key: "auto_select_min_seeders").update!(
      value: "100",
      value_type: "integer",
      category: "auto_select"
    )

    # Usenet result has no seeders but download_url with nzb
    result = create_search_result(
      seeders: nil,
      download_url: "http://example.com/download.nzb"
    )

    assert_enqueued_with(job: DownloadJob) do
      selection = AutoSelectService.call(@request)

      assert selection.success?
      assert_equal :auto_selected, selection.reason
    end

    assert result.reload.selected?
  end

  test "direct download results bypass seeder check" do
    Setting.find_or_create_by(key: "auto_select_min_seeders").update!(
      value: "100",
      value_type: "integer",
      category: "auto_select"
    )

    result = create_search_result(
      seeders: nil,
      source: SearchResult::SOURCE_ZLIBRARY,
      download_url: nil,
      magnet_url: nil
    )

    assert_enqueued_with(job: DownloadJob) do
      selection = AutoSelectService.call(@request)

      assert selection.success?
      assert_equal :auto_selected, selection.reason
    end

    assert result.reload.selected?
  end

  test "custom provider direct results bypass seeder check" do
    Setting.find_or_create_by(key: "auto_select_min_seeders").update!(
      value: "100",
      value_type: "integer",
      category: "auto_select"
    )
    provider = AcquisitionProvider.create!(
      name: "Custom Provider",
      url: "http://provider.test"
    )

    result = create_search_result(
      seeders: nil,
      source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: provider,
      provider_result_id: "custom-direct",
      provider_payload: { "download_type" => "direct" },
      download_url: nil,
      magnet_url: nil
    )

    assert_enqueued_with(job: DownloadJob) do
      selection = AutoSelectService.call(@request)

      assert selection.success?
      assert_equal :auto_selected, selection.reason
    end

    assert result.reload.selected?
  end

  test "creates download record and enqueues job on success" do
    result = create_search_result(
      title: "Test Book - Audiobook",
      seeders: 10,
      size_bytes: 500_000_000,
      magnet_url: "magnet:?test"
    )

    assert_difference "@request.downloads.count", 1 do
      assert_enqueued_with(job: DownloadJob) do
        AutoSelectService.call(@request)
      end
    end

    download = @request.downloads.last
    assert_equal "Test Book - Audiobook", download.name
    assert_equal 500_000_000, download.size_bytes
    assert download.queued?
  end

  test "selects best result first based on ordering" do
    # Create results with different quality levels
    low_seeder = create_search_result(seeders: 5, magnet_url: "magnet:?low")
    high_seeder = create_search_result(seeders: 100, magnet_url: "magnet:?high")

    selection = AutoSelectService.call(@request)

    assert selection.success?
    # best_first scope orders by preferred type then seeders desc
    assert_equal high_seeder, selection.search_result
  end

  test "skips blocklisted best candidate and selects next eligible result" do
    blocklisted = create_search_result(seeders: 100, magnet_url: "magnet:?blocked")
    blocklisted.blocklist!("Previous failure")
    fallback = create_search_result(seeders: 10, magnet_url: "magnet:?fallback")

    selection = AutoSelectService.call(@request)

    assert selection.success?
    assert_equal fallback, selection.search_result
    assert blocklisted.reload.blocklisted?
    assert fallback.reload.selected?
  end

  test "returns no matching results when all matching candidates are blocklisted" do
    blocklisted = create_search_result(seeders: 100, magnet_url: "magnet:?blocked")
    blocklisted.blocklist!("Previous failure")

    selection = AutoSelectService.call(@request)

    refute selection.success?
    assert_equal :no_matching_results, selection.reason
    assert_equal 0, @request.downloads.count
  end

  test "rejects other results when selecting" do
    selected = create_search_result(seeders: 100, magnet_url: "magnet:?best")
    other1 = create_search_result(seeders: 50, magnet_url: "magnet:?other1")
    other2 = create_search_result(seeders: 25, magnet_url: "magnet:?other2")

    perform_enqueued_jobs do
      AutoSelectService.call(@request)
    end

    assert selected.reload.selected?
    assert other1.reload.rejected?
    assert other2.reload.rejected?
  end

  test "skips blocked formats and selects next allowed result" do
    SettingsService.set(:ebook_rejected_formats, [ "mobi" ])

    blocked = create_search_result(
      title: "Test Result English EPUB MOBI",
      seeders: 100,
      magnet_url: "magnet:?blocked",
      confidence_score: 99
    )
    allowed = create_search_result(
      title: "Test Result English EPUB",
      seeders: 10,
      magnet_url: "magnet:?allowed",
      confidence_score: 95
    )

    selection = AutoSelectService.call(@request)

    assert selection.success?
    assert_equal allowed, selection.search_result
    assert blocked.reload.rejected?
  end

  test "does not auto-select a confidently conflicting comic issue" do
    @book.update!(
      title: "Saga",
      author: "Brian K. Vaughan",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-437",
      issue_number: "7",
      series: "Saga",
      series_position: "7"
    )
    result = create_search_result(
      title: "Saga #8 English Comic CBZ",
      seeders: 100,
      magnet_url: "magnet:?conflicting-issue"
    )
    result.calculate_score!

    selection = AutoSelectService.call(@request)

    assert_not selection.success?
    assert_equal :no_matching_results, selection.reason
    assert result.reload.pending?
    assert_equal 0, @request.downloads.count
  end

  test "does not auto-select a comic issue from a conflicting release year" do
    @book.update!(
      title: "Batman - #1 - The Legend of the Batman",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-105811",
      issue_number: "1",
      series: "Batman",
      series_position: "1",
      release_date: Date.new(2018, 4, 1),
      series_start_year: 1940
    )
    result = create_search_result(
      title: "Batman #001 (2016) English Comic CBZ",
      seeders: 100,
      magnet_url: "magnet:?conflicting-run"
    )
    result.calculate_score!

    selection = AutoSelectService.call(@request)

    assert_not selection.success?
    assert_equal :no_matching_results, selection.reason
    assert result.reload.pending?
    assert_equal 0, @request.downloads.count
  end

  test "does not auto-select a multi-issue comic pack" do
    @book.update!(
      title: "Saga - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-438",
      issue_number: "1",
      series: "Saga",
      series_position: "1"
    )
    result = create_search_result(
      title: "Saga #001-#006 English Comic CBZ",
      seeders: 100,
      magnet_url: "magnet:?issue-pack"
    )
    result.calculate_score!

    selection = AutoSelectService.call(@request)

    assert_not selection.success?
    assert_equal :no_matching_results, selection.reason
    assert result.reload.pending?
    assert_equal 0, @request.downloads.count
  end

  test "does not auto-select an exact comic issue with a conflicting format" do
    @book.update!(
      title: "Saga - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-439",
      issue_number: "7",
      series: "Saga",
      series_position: "7"
    )
    result = create_search_result(
      title: "Saga #007 English EPUB",
      seeders: 100,
      magnet_url: "magnet:?conflicting-format"
    )
    result.calculate_score!

    selection = AutoSelectService.call(@request)

    assert_not selection.success?
    assert_equal :no_matching_results, selection.reason
    assert_equal :exact, result.score_breakdown["issue_match"].to_sym
    assert_equal 0, result.score_breakdown["format"]
    assert_not result.score_breakdown["auto_select_allowed"]
    assert result.reload.pending?
    assert_equal 0, @request.downloads.count
  end

  test "does not auto-select when the requested series is only a release title suffix" do
    assert_comic_title_not_auto_selected(
      series: "X",
      issue: "7",
      title: "Generation X #007 English Comic CBZ"
    )
  end

  test "does not auto-select a whitespace-separated comic issue pack" do
    assert_comic_title_not_auto_selected(
      series: "Saga",
      issue: "1",
      title: "Saga #001 002 English Comic CBZ"
    )
  end

  test "does not auto-select a partially consumed comic issue label" do
    assert_comic_title_not_auto_selected(
      series: "Saga",
      issue: "1",
      title: "Saga #1-A English Comic CBZ"
    )
  end

  test "does not auto-select a punctuation-extended series identity" do
    assert_comic_title_not_auto_selected(
      series: "X",
      issue: "23",
      title: "X-23 English Comic CBZ"
    )
  end

  test "does not auto-select an issue pack with a language word separator" do
    assert_comic_title_not_auto_selected(
      series: "Saga",
      issue: "1",
      title: "Saga #1 y 2 English Comic CBZ"
    )
  end

  test "does not auto-select a marked year-shaped issue pack" do
    assert_comic_title_not_auto_selected(
      series: "2000 AD",
      issue: "2000",
      title: "2000.AD #2000 and #2012 English Comic CBZ"
    )
  end

  test "does not auto-select an issue marker consumed as series punctuation" do
    assert_comic_title_not_auto_selected(
      series: "X-23",
      issue: "7",
      title: "X #23 #007 English Comic CBZ"
    )
  end

  test "does not auto-select a conflicting unwrapped release year" do
    assert_comic_title_not_auto_selected(
      series: "Batman",
      issue: "1",
      release_date: Date.new(2018, 4, 1),
      series_start_year: 1940,
      title: "2016 Batman #001 English Comic CBZ"
    )
  end

  test "selection result error reason works" do
    # Test that the SelectionResult with error reason works correctly
    result = AutoSelectService::SelectionResult.new(selected: false, reason: :error)

    refute result.success?
    assert_equal :error, result.reason
    assert_nil result.search_result
  end

  private

  def assert_comic_title_not_auto_selected(
    series:,
    issue:,
    title:,
    release_date: nil,
    series_start_year: nil
  )
    @book.update!(
      title: "#{series} - ##{issue}",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-#{SecureRandom.random_number(1_000_000_000)}",
      issue_number: issue,
      series: series,
      series_position: issue,
      release_date: release_date,
      series_start_year: series_start_year
    )
    result = create_search_result(
      title: title,
      seeders: 100,
      magnet_url: "magnet:?#{SecureRandom.hex(20)}"
    )
    result.calculate_score!

    selection = AutoSelectService.call(@request)

    assert_not selection.success?
    assert_equal :no_matching_results, selection.reason
    assert result.reload.pending?
    assert_equal 0, @request.downloads.count
  end

  def create_search_result(attrs = {})
    result = @request.search_results.create!({
      guid: SecureRandom.uuid,
      title: "Test Result English Audiobook",
      indexer: "TestIndexer",
      status: :pending,
      confidence_score: 95,
      detected_language: "en"
    }.merge(attrs))
    result
  end
end
