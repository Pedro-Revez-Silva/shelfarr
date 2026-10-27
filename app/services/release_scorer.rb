# frozen_string_literal: true

class ReleaseScorer
  COMIC_ISSUE_EXACT_BONUS = 15
  COMIC_ISSUE_UNKNOWN_MAX_SCORE = 49
  COMIC_ISSUE_VALUE_PATTERN = '\d+(?:\.\d+)?(?:[a-z]|-[a-z])?'

  WEIGHTS = {
    title: 40,      # How well does the release title match the book title?
    author: 20,     # Is the author name present in the release title?
    language: 25,   # Does it match the requested language?
    format: 10,     # Does the format (audiobook/ebook) match?
    health: 5
  }.freeze

  Result = Data.define(:total, :breakdown, :detected_languages, :detected_format) do
    def high_confidence?
      total >= 90
    end

    def medium_confidence?
      total >= 70 && total < 90
    end

    def low_confidence?
      total < 70
    end
  end

  def initialize(search_result, request)
    @search_result = search_result
    @request = request
    @book = request.book
    @parsed = ReleaseParserService.parse(search_result.title)
    @format_preferences = FormatPreferenceService.evaluate(title: search_result.title, book_type: @book.book_type, parsed: @parsed)
    @comic_issue_match = classify_comic_issue_match
  end

  def score
    issue_status = @comic_issue_match&.fetch(:status, nil)
    format_score = calculate_format_score
    auto_select_allowed = @format_preferences.auto_select_allowed &&
      !explicit_format_conflict? &&
      !ambiguous_title_alias_match? &&
      (@comic_issue_match.nil? || issue_status == :exact)
    breakdown = {
      title: calculate_title_score,
      author: calculate_author_score,
      language: calculate_language_score,
      format: format_score,
      health: calculate_health_score,
      preference_adjustment: @format_preferences.score_adjustment,
      auto_select_allowed: auto_select_allowed,
      extension: @format_preferences.matched_extension,
      extensions: @format_preferences.detected_extensions,
      audiobook_structure: @format_preferences.audiobook_structure,
      audio_bitrate_kbps: @format_preferences.audio_bitrate_kbps
    }
    if @comic_issue_match
      breakdown.merge!(
        issue_match: @comic_issue_match[:status],
        requested_issue_number: @comic_issue_match[:requested],
        detected_issue_number: @comic_issue_match[:detected],
        issue_adjustment: comic_issue_adjustment
      )
    end

    base_total = WEIGHTS.sum do |key, weight|
      (breakdown[key] * weight) / 100.0
    end.round

    total = (base_total + @format_preferences.score_adjustment + comic_issue_adjustment).clamp(0, 100)
    total = [ total, COMIC_ISSUE_UNKNOWN_MAX_SCORE ].min if issue_status == :unknown
    total = 0 if issue_status == :mismatch

    Result.new(
      total: total,
      breakdown: breakdown,
      detected_languages: @parsed[:languages],
      detected_format: @parsed[:format]
    )
  end

  class << self
    def score(search_result, request)
      new(search_result, request).score
    end
  end

  private

  def calculate_title_score
    return 100 if @comic_issue_match&.fetch(:status, nil) == :exact
    return 0 if SequenceMarkers.conflict?(@book.title, @search_result.title)

    release_key = normalized_title_key(@search_result.title)
    title_variants = SearchTitleVariantService.call(@book.title)
    book_titles = title_variants
      .map { |title| normalized_title_key(title).canonical }
      .reject(&:blank?)

    return 0 if release_key.canonical.blank? || book_titles.empty?

    # Localized/original title aliases are equivalent only as complete phrases.
    # Very short inferred titles are too collision-prone unless they lead the
    # release name (for example, "It" must not match "The Institute").
    if title_variants.any? { |title| exact_normalized_title_match?(title) }
      100
    else
      book_titles.map { |title| trigram_similarity(release_key.canonical, title) }.max
    end
  end

  def exact_title_phrase_match?(release_title, book_title, short_title:)
    phrase = /(?:\A|\s)#{Regexp.escape(book_title)}(?:\z|\s)/
    return false unless release_title.match?(phrase)
    return true unless short_title

    release_title == book_title || release_title.start_with?("#{book_title} ")
  end

  def exact_normalized_title_match?(book_title)
    book_key = normalized_title_key(book_title)
    release_key = normalized_title_key(@search_result.title)
    book_key.forms.any? do |title|
      release_key.forms.any? do |release_title|
        exact_title_phrase_match?(release_title, title, short_title: book_key.short?)
      end
    end
  end

  def normalized_title_key(title)
    TitleKey.new(SequenceMarkers.normalize(title))
  end

  def ambiguous_title_alias_match?
    variants = SearchTitleVariantService.call(@book.title)
    return false if variants.length < 3

    !exact_normalized_title_match?(@book.title)
  end

  def calculate_author_score
    return 50 if @comic_issue_match&.fetch(:status, nil) == :exact
    return 50 if @book.author.blank?  # Neutral if no author to match

    release_key = TitleKey.new(@search_result.title)
    author_key = TitleKey.new(@book.author)
    release_title = release_key.canonical
    author = author_key.canonical

    return 0 if release_title.blank? || author.blank?

    return 100 if release_key.substring_forms.any? do |title|
      author_key.substring_forms.any? { |name| title.include?(name) }
    end

    author_parts = author.split
    if author_parts.length > 1
      last_name = author_parts.last
      return 80 if release_title.include?(last_name) && last_name.length > 3
    end

    first_name = author_parts.first
    return 40 if release_title.include?(first_name) && first_name.length > 3

    0
  end

  # Language matching score (0-100)
  # 100 = matches requested, 50 = unknown/multi, 0 = wrong language
  def calculate_language_score
    requested_language = @request.language || SettingsService.get(:default_language)
    detected = @parsed[:languages]

    # Multi-language releases match any language
    return 100 if @parsed[:is_multi_language]

    # No language detected - treat as neutral (might match, might not)
    return 50 if detected.empty?

    return 100 if detected.include?(requested_language)

    0
  end

  def calculate_format_score
    detected = @parsed[:format]
    requested = @book.book_type&.to_sym

    return 50 if detected.nil?

    case requested
    when :audiobook
      detected == :audiobook ? 100 : 0
    when :ebook
      detected == :ebook ? 100 : 0
    when :comicbook
      detected == :comicbook ? 100 : 0
    else
      50
    end
  end

  # Health/availability score (0-100)
  # Based on seeders for torrents, always 100 for usenet
  def calculate_health_score
    # Usenet always has full availability
    return 100 if usenet?

    seeders = @search_result.seeders || 0

    # Normalize seeders to 0-100 scale
    # 0 seeders = 0, 1-5 = 20-60, 5-20 = 60-80, 20+ = 80-100
    case seeders
    when 0
      0
    when 1..5
      20 + (seeders * 8)
    when 6..20
      60 + ((seeders - 5) * 1.3).round
    else
      [ 80 + ((seeders - 20) * 0.2).round, 100 ].min
    end
  end

  def usenet?
    # Usenet results typically have download_url but no magnet and no seeders
    @search_result.download_url.present? &&
      @search_result.magnet_url.blank? &&
      @search_result.seeders.nil?
  end

  def comic_issue_adjustment
    @comic_issue_match&.fetch(:status, nil) == :exact ? COMIC_ISSUE_EXACT_BONUS : 0
  end

  def classify_comic_issue_match
    requested = @book.issue_number_for_matching
    return unless requested

    detected = detect_comic_issue_number
    return { status: :unknown, requested: requested, detected: nil } unless detected
    return { status: :unknown, requested: requested, detected: detected[:value] } if detected[:ambiguous]

    normalized_requested = normalize_issue_number(requested)
    normalized_detected = normalize_issue_number(detected[:value])
    status = if normalized_requested == normalized_detected
      comic_issue_run_year_conflict?(detected) ? :unknown : :exact
    elsif numeric_issue_number?(normalized_requested) && numeric_issue_number?(normalized_detected)
      :mismatch
    else
      :unknown
    end

    { status: status, requested: requested, detected: detected[:value] }
  end

  def detect_comic_issue_number
    title = @search_result.title.to_s
    series_tokens = @book.series.to_s.downcase.scan(/[[:alnum:]]+/)
    return if series_tokens.empty?

    separator = '[\s._:–—-]'
    series_separator = "[\\s._:,&/'’()!?+\\[\\]–—-]"
    run_year = '(?:19|20)\d{2}'
    year_metadata = "(?:[\\(\\[]#{run_year}[\\)\\]]|#{run_year})"
    series_pattern = series_tokens.map { |token| Regexp.escape(token) }.join("#{series_separator}*")
    series_match = title.match(
      /\A#{separator}*(?:#{year_metadata}#{separator}+)*?(?<series>#{series_pattern})(?![[:alnum:]])/i
    )
    return unless series_match

    series_range = series_match.begin(:series)...series_match.end(:series)
    tail_offset = series_match.end(:series)
    tail = title[tail_offset..]
    marker = '(?:#|(?<![[:alnum:]])(?:issues?|no\.?|numbers?)(?![[:alnum:]])\s*#?\s*)'
    issue_value = COMIC_ISSUE_VALUE_PATTERN
    issue = "(?<issue>#{issue_value})"
    issue_terminator = '(?=\z|\s|[._:\(\[])'
    tail, consumed = extract_leading_comic_run_year(tail, separator:, marker:, issue_value:)
    tail_offset += consumed

    explicit = tail.match(/\A#{separator}*#{marker}\s*#{issue}#{issue_terminator}/i)
    if explicit
      return comic_issue_detection(
        explicit,
        tail,
        title: title,
        series_range: series_range,
        tail_offset: tail_offset,
        marker: marker,
        issue_value: issue_value
      )
    end

    plain = tail.match(/\A\s+#{issue}#{issue_terminator}/i)
    return unless plain
    return if plain[:issue].match?(/\A(?:19|20)\d{2}\z/)

    comic_issue_detection(
      plain,
      tail,
      title: title,
      series_range: series_range,
      tail_offset: tail_offset,
      marker: marker,
      issue_value: issue_value
    )
  end

  def extract_leading_comic_run_year(tail, separator:, marker:, issue_value:)
    wrapped = tail.match(/\A#{separator}*[\(\[](?<year>(?:19|20)\d{2})[\)\]]/)
    return [ tail[wrapped.end(0)..], wrapped.end(0) ] if wrapped

    plain = tail.match(
      /\A#{separator}*(?<year>(?:19|20)\d{2})(?=#{separator}+(?:#{marker})?#{issue_value}(?![[:alnum:]]))/i
    )
    return [ tail[plain.end(0)..], plain.end(0) ] if plain

    [ tail, 0 ]
  end

  def comic_issue_detection(match, tail, title:, series_range:, tail_offset:, marker:, issue_value:)
    issue_range = (tail_offset + match.begin(:issue))...(tail_offset + match.end(:issue))
    run_years = comic_run_years(title, excluded_ranges: [ series_range, issue_range ])
    remainder = tail[match.end(0)..]
    ambiguous = run_years.many? || additional_comic_issue?(remainder, marker:, issue_value:, run_years:)

    { value: match[:issue], ambiguous: ambiguous, run_year: run_years.one? ? run_years.first : nil }
  end

  def comic_run_years(title, excluded_ranges:)
    title.to_enum(
      :scan,
      /(?<![[:alnum:]])(?<year>(?:19|20)\d{2})(?![[:alnum:]])/
    ).filter_map do
      match = Regexp.last_match
      range = match.begin(:year)...match.end(:year)
      next if excluded_ranges.any? { |excluded| ranges_overlap?(range, excluded) }

      match[:year].to_i
    end.uniq
  end

  def ranges_overlap?(left, right)
    left.begin < right.end && right.begin < left.end
  end

  def additional_comic_issue?(tail, marker:, issue_value:, run_years:)
    return true if tail.match?(/#{marker}\s*#{issue_value}(?![[:alnum:]])/i)

    tail.to_enum(
      :scan,
      /(?<![[:alnum:]])(?<additional>#{issue_value})(?![[:alnum:]])/i
    ).any? do
      additional_comic_issue_value?(Regexp.last_match[:additional], run_years)
    end
  end

  def additional_comic_issue_value?(value, run_years)
    !value.match?(/\A(?:19|20)\d{2}\z/) || !run_years.include?(value.to_i)
  end

  def comic_issue_run_year_conflict?(detected)
    return false if detected[:run_year].blank?

    requested_year = @book.series_start_year
    return @book.comic_vine_id.to_s.start_with?("4000-") if requested_year.blank?

    detected[:run_year] != requested_year
  end

  def explicit_format_conflict?
    detected = @parsed[:format]
    requested = @book.book_type&.to_sym
    detected.present? && requested.in?([ :audiobook, :ebook, :comicbook ]) && detected != requested
  end

  def normalize_issue_number(value)
    normalized = value.to_s.delete_prefix("#").squish.downcase
    numeric_stem = normalized.match(/\A0*(\d+)((?:\.\d+)?(?:[a-z]|-[a-z])?)\z/i)
    return normalized unless numeric_stem

    "#{numeric_stem[1].to_i}#{numeric_stem[2]}"
  end

  def numeric_issue_number?(value)
    value.to_s.match?(/\A\d+\z/)
  end

  def trigram_similarity(str1, str2)
    return 100 if str1 == str2
    return 0 if str1.blank? || str2.blank?

    trigrams1 = to_trigrams(str1)
    trigrams2 = to_trigrams(str2)

    return 0 if trigrams1.empty? || trigrams2.empty?

    intersection = (trigrams1 & trigrams2).size
    union = (trigrams1 | trigrams2).size

    ((intersection.to_f / union) * 100).round
  end

  def to_trigrams(str)
    padded = "  #{str}  "
    (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
  end
end
