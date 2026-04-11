# frozen_string_literal: true

class FormatPreferenceService
  Result = Data.define(
    :score_adjustment,
    :auto_select_allowed,
    :matched_extension,
    :detected_extensions,
    :audiobook_structure,
    :audio_bitrate_kbps
  )

  REJECTED_FORMAT_PENALTY = -35
  NON_APPROVED_FORMAT_PENALTY = -20
  NON_PREFERRED_FORMAT_PENALTY = -6
  SINGLE_FILE_BONUS = 6
  MULTI_FILE_PENALTY = -6
  PREFERRED_FORMAT_BONUSES = [ 12, 8, 4, 2 ].freeze

  def self.evaluate(title:, book_type:)
    new(title:, book_type:).evaluate
  end

  def initialize(title:, book_type:)
    @title = title
    @book_type = book_type.to_s
    @parsed = ReleaseParserService.parse(title)
    @preferences = SettingsService.format_preferences_for(@book_type)
  end

  def evaluate
    matched_extension = select_extension
    score_adjustment = 0
    auto_select_allowed = true

    if rejected_format?(matched_extension)
      score_adjustment += REJECTED_FORMAT_PENALTY
      auto_select_allowed = false
    elsif disallowed_by_approved_formats?(matched_extension)
      score_adjustment += NON_APPROVED_FORMAT_PENALTY
      auto_select_allowed = false
    end

    score_adjustment += preferred_format_adjustment(matched_extension)
    score_adjustment += audiobook_structure_adjustment
    score_adjustment += bitrate_adjustment

    Result.new(
      score_adjustment: score_adjustment,
      auto_select_allowed: auto_select_allowed,
      matched_extension: matched_extension,
      detected_extensions: @parsed[:extensions],
      audiobook_structure: @parsed[:audiobook_structure],
      audio_bitrate_kbps: @parsed[:audio_bitrate_kbps]
    )
  end

  private

  def select_extension
    detected_extensions = @parsed[:extensions]
    return @parsed[:primary_extension].presence if detected_extensions.empty?

    @preferences[:preferred_formats].each do |extension|
      return extension if detected_extensions.include?(extension)
    end

    @preferences[:approved_formats].each do |extension|
      return extension if detected_extensions.include?(extension)
    end

    @parsed[:primary_extension].presence || detected_extensions.first
  end

  def rejected_format?(_matched_extension)
    return false if @parsed[:extensions].empty?

    (@parsed[:extensions] & @preferences[:rejected_formats]).any?
  end

  def disallowed_by_approved_formats?(_matched_extension)
    approved_formats = @preferences[:approved_formats]
    return false if approved_formats.empty? || @parsed[:extensions].empty?

    (@parsed[:extensions] & approved_formats).empty?
  end

  def preferred_format_adjustment(matched_extension)
    preferred_formats = @preferences[:preferred_formats]
    return 0 if preferred_formats.empty? || matched_extension.blank?

    preferred_index = preferred_formats.index(matched_extension)
    return NON_PREFERRED_FORMAT_PENALTY if preferred_index.nil?

    PREFERRED_FORMAT_BONUSES.fetch(preferred_index, 1)
  end

  def audiobook_structure_adjustment
    return 0 unless @book_type == "audiobook"
    return 0 unless @preferences[:prefer_single_file]

    case @parsed[:audiobook_structure]
    when :single_file then SINGLE_FILE_BONUS
    when :multi_file then MULTI_FILE_PENALTY
    else 0
    end
  end

  def bitrate_adjustment
    return 0 unless @book_type == "audiobook"
    return 0 unless @preferences[:prefer_higher_bitrate]

    bitrate = @parsed[:audio_bitrate_kbps].to_i

    case bitrate
    when 256.. then 6
    when 192...256 then 4
    when 128...192 then 2
    else 0
    end
  end
end
