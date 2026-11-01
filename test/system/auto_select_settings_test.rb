require "application_system_test_case"

class AutoSelectSettingsTest < ApplicationSystemTestCase
  SAVE_STATUS = "[data-settings-form-target~='status']"

  setup do
    @admin = users(:two)
    @request = requests(:pending_request)
  end

  test "admins tune the auto-select threshold and see out-of-range sizes on every result list" do
    sign_in_as(@admin)
    visit admin_settings_path

    assert_field "Auto-Select Confidence Threshold", with: "90"
    fill_in "Auto-Select Confidence Threshold", with: "75"
    blur_field "Auto-Select Confidence Threshold"
    assert_setting_equals :auto_select_confidence_threshold, 75
    assert_selector SAVE_STATUS, exact_text: "Saved."

    click_button "Downloads"
    assert_field "Maximum Ebook Size", with: ""
    assert_text "Leave blank for no limit. A number alone is megabytes."
    fill_in "Maximum Ebook Size", with: "20"
    blur_field "Maximum Ebook Size"
    assert_setting_equals :ebook_max_file_size, "20 MB"
    assert_selector SAVE_STATUS, exact_text: "Saved."

    visit admin_settings_path(tab: "downloads")
    assert_field "Minimum Ebook Size", with: ""
    assert_field "Maximum Ebook Size", with: "20 MB"
    assert_field "Minimum Audiobook Size", with: ""
    assert_field "Maximum Audiobook Size", with: ""
    click_button "Search"
    assert_field "Auto-Select Confidence Threshold", with: "75"

    oversized, within_range = scored_ebook_results
    visit requests_path(q: "The Pending Ebook")
    within(request_card) do
      click_button "View Results (2)"
      assert_size_penalty(oversized)
      assert_size_neutral(within_range)
    end

    visit request_path(@request)
    assert_size_penalty(oversized)
    assert_size_neutral(within_range)

    visit admin_request_search_results_path(@request)
    assert_size_penalty(oversized)
    assert_size_neutral(within_range)
    assert_selector "span[title='Larger than the configured maximum file size']", text: "Size -40 (too large)"
  end

  test "ebook and audiobook size limits stay on screen on a phone" do
    page.current_window.resize_to(390, 844)
    sign_in_as(@admin)
    visit admin_settings_path(tab: "downloads")

    assert_field "Minimum Ebook Size"
    assert_field "Maximum Ebook Size"
    assert_field "Minimum Audiobook Size"
    assert_field "Maximum Audiobook Size"
    assert_text "A release outside the range is scored down and kept for manual review."
  end

  private

  def blur_field(label)
    find_field(label).send_keys(:tab)
  end

  def assert_setting_equals(key, expected)
    using_wait_time(5) do
      page.document.synchronize do
        actual = SettingsService.get(key)
        raise Capybara::ExpectationNotMet, "#{key} is #{actual.inspect}" unless actual == expected
      end
    end
  end

  def scored_ebook_results
    @request.search_results.destroy_all
    oversized = build_ebook_result("oversized-ebook", 80.megabytes, "magnet:?xt=urn:btih:oversizedebook01")
    within_range = build_ebook_result("within-range-ebook", 5.megabytes, "magnet:?xt=urn:btih:withinrangeebook1")
    [ oversized, within_range ].each(&:calculate_score!)
    assert_equal "above_max", oversized.score_breakdown["file_size_status"]
    assert_equal "within", within_range.score_breakdown["file_size_status"]
    assert within_range.auto_select_allowed_by_preferences?
    [ oversized, within_range ]
  end

  def build_ebook_result(guid, size_bytes, magnet_url)
    @request.search_results.create!(
      guid: guid,
      title: "The Pending Ebook - Another Author English EPUB",
      indexer: "TestIndexer",
      size_bytes: size_bytes,
      seeders: 20,
      magnet_url: magnet_url,
      status: :pending
    )
  end

  def request_card
    find("[data-controller='search-results']", text: "The Pending Ebook")
  end

  def assert_size_penalty(result)
    within(result_row(result)) do
      assert_text "Size -40 (too large)"
      assert_text "Manual review"
    end
  end

  def assert_size_neutral(result)
    within(result_row(result)) do
      assert_no_text "Size -40"
      assert_no_text "too small"
      assert_no_text "too large"
      assert_no_text "Manual review"
    end
  end

  def result_row(result)
    find("[data-search-result-id='#{result.id}']")
  end
end
