# frozen_string_literal: true

require "test_helper"

class FormatPreferenceServiceTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    SettingsService.set(:audiobook_approved_formats, [])
    SettingsService.set(:audiobook_rejected_formats, [])
    SettingsService.set(:audiobook_preferred_formats, [])
    SettingsService.set(:audiobook_prefer_single_file, false)
    SettingsService.set(:audiobook_prefer_higher_bitrate, false)
  end

  test "rejected formats are excluded from auto selection" do
    SettingsService.set(:audiobook_rejected_formats, [ "mp3" ])

    result = FormatPreferenceService.evaluate(
      title: "Book Title Audiobook MP3 128kbps",
      book_type: :audiobook
    )

    refute result.auto_select_allowed
    assert_equal "mp3", result.matched_extension
    assert_operator result.score_adjustment, :<=, -35
  end

  test "preferred formats use configured ranking order" do
    SettingsService.set(:ebook_preferred_formats, [ "epub", "pdf" ])

    result = FormatPreferenceService.evaluate(
      title: "Book Title PDF EPUB",
      book_type: :ebook
    )

    assert result.auto_select_allowed
    assert_equal "epub", result.matched_extension
    assert_equal 12, result.score_adjustment
  end

  test "single file and bitrate preferences add audiobook bonuses" do
    SettingsService.set(:audiobook_prefer_single_file, true)
    SettingsService.set(:audiobook_prefer_higher_bitrate, true)

    result = FormatPreferenceService.evaluate(
      title: "Book Title Audiobook M4B 256kbps",
      book_type: :audiobook
    )

    assert result.auto_select_allowed
    assert_equal :single_file, result.audiobook_structure
    assert_equal 256, result.audio_bitrate_kbps
    assert_equal 12, result.score_adjustment
  end
end
