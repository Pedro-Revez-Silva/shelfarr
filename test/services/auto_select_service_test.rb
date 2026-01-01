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

  test "selection result error reason works" do
    # Test that the SelectionResult with error reason works correctly
    result = AutoSelectService::SelectionResult.new(selected: false, reason: :error)

    refute result.success?
    assert_equal :error, result.reason
    assert_nil result.search_result
  end

  private

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
